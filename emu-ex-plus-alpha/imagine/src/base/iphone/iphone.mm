#define thisModuleName "base:iphone"

#import "MainApp.h"
#import "EAGLView.h"
#import <dlfcn.h>
#import <unistd.h>

#include <base/Base.hh>
#include <base/iphone/private.hh>
#include <fs/sys.hh>
#include <config/machine.hh>
#include <util/time/sys.hh>
#include <base/common/funcs.h>

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGLDrawable.h>
#import <Foundation/NSPathUtilities.h>

namespace Base
{
	static UIWindow *devWindow;
	static int pointScale = 1;
	static MainApp *mainApp;
}

static CGAffineTransform makeTransformForOrientation(uint orientation)
{
	using namespace Gfx;
	switch(orientation)
	{
		default: return CGAffineTransformIdentity;
		case VIEW_ROTATE_270: return CGAffineTransformMakeRotation(3*M_PI / 2.0);
		case VIEW_ROTATE_90: return CGAffineTransformMakeRotation(M_PI / 2.0);
		case VIEW_ROTATE_180: return CGAffineTransformMakeRotation(M_PI);
	}
}


#if defined(CONFIG_INPUT) && defined(IPHONE_VKEYBOARD)
namespace Input
{
	//static UITextView *vkbdField = nil;
	static UITextField *vkbdField = nil;
	//static bool inVKeyboard = 0;
	static InputTextDelegate vKeyboardTextDelegate;
	static Rect2<int> textRect(8, 200, 8+304, 200+48);
}
#endif

#ifdef CONFIG_INPUT
	#include "input.h"
#endif

#ifdef CONFIG_INPUT_ICADE
	#include "ICadeHelper.hh"
#endif

namespace Base
{

struct ThreadMsg
{
	int16 type;
	int16 shortArg;
	int intArg;
	int intArg2;
};

const char *appPath = 0;
static UIWindow *externalWindow = 0;
static EAGLView *glView;
static EAGLContext *mainContext = nullptr;
static CADisplayLink *displayLink = 0;
static BOOL displayLinkActive = NO;
static bool isIPad = 0;
static bool useMaxColorBits = Config::MACHINE_IS_GENERIC_ARMV7;
#ifdef __ARM_ARCH_6K__
static bool usingiOS4 = 0;
#else
static const bool usingiOS4 = 1; // always on iOS 4.3+ when compiled for ARMv7
#endif
;
#ifdef CONFIG_INPUT_ICADE
static ICadeHelper iCade = { nil };
#endif
CGColorSpaceRef grayColorSpace = nullptr, rgbColorSpace = nullptr;

// used on iOS 4.0+
static UIViewController *viewCtrl;

#ifdef IPHONE_IMG_PICKER
	static UIImagePickerController* imagePickerController;
	static IPhoneImgPickerCallback imgPickCallback = NULL;
	static void *imgPickUserPtr = NULL;
	static NSData *imgPickData[2];
	static uchar imgPickDataElements = 0;
	#include "imagePicker.h"
#endif

#ifdef IPHONE_MSG_COMPOSE
	static MFMailComposeViewController *composeController;
	#include "mailCompose.h"
#endif

#ifdef IPHONE_GAMEKIT
	#include "gameKit.h"
#endif

#ifdef GREYSTRIPE
    #include "greystripe.h"
#endif

static const int USE_DEPTH_BUFFER = 0;
static int openglViewIsInit = 0;

void cancelCallback(CallbackRef *ref)
{
	if(ref)
	{
		logMsg("cancelling callback with ref %p", ref);
		[NSObject cancelPreviousPerformRequestsWithTarget:mainApp selector:@selector(timerCallback:) object:(id)ref];
	}
}

CallbackRef *callbackAfterDelay(CallbackDelegate callback, int ms)
{
	logMsg("setting callback to run in %d ms", ms);
	CallbackDelegate del(callback);
	NSData *callbackArg = [[NSData alloc] initWithBytes:&del length:sizeof(del)];
	assert(callbackArg);
	[mainApp performSelector:@selector(timerCallback:) withObject:(id)callbackArg afterDelay:(float)ms/1000.];
	[callbackArg release];
	return (CallbackRef*)callbackArg;
}

void openGLUpdateScreen()
{
	//logMsg("doing swap");
	//glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
	[Base::mainContext presentRenderbuffer:GL_RENDERBUFFER_OES];
}

void startAnimation()
{
	if(!Base::displayLinkActive)
	{
		displayLink.paused = NO; 
		Base::displayLinkActive = YES;
	}
}

void stopAnimation()
{
	if(Base::displayLinkActive)
	{
		displayLink.paused = YES;
		Base::displayLinkActive = NO;
	}
}

uint appState = APP_RUNNING;

}

@interface ImagineUIViewController : UIViewController

@end

@implementation ImagineUIViewController

- (BOOL)shouldAutorotate
{
	return NO;
}

@end

// A class extension to declare private methods
@interface EAGLView ()

@property (nonatomic, retain) EAGLContext *context;

- (BOOL) createFramebuffer;
- (void) destroyFramebuffer;

@end

@implementation EAGLView

@synthesize context;

// Implement this to override the default layer class (which is [CALayer class]).
// We do this so that our view will be backed by a layer that is capable of OpenGL ES rendering.
+ (Class)layerClass
{
	return [CAEAGLLayer class];
}

-(id)initGLES
{
	CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;

	#if !defined(__ARM_ARCH_6K__)
	using namespace Base;
	if(usingiOS4)
	{
		logMsg("testing for Retina Display");
		if([UIScreen mainScreen].scale == 2.0)
		{
			logMsg("running on Retina Display");
			eaglLayer.contentsScale = 2.0;
			pointScale = 2;
			mainWin.rect.x2 *= 2;
			mainWin.rect.y2 *= 2;
			mainWin.w *= 2;
			mainWin.h *= 2;
			currWin = mainWin;
	    }
	}
	#endif

	self.multipleTouchEnabled = YES;
	eaglLayer.opaque = YES;
	if(!Base::useMaxColorBits)
	{
		logMsg("using RGB565 surface");
		eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
			kEAGLColorFormatRGB565, kEAGLDrawablePropertyColorFormat, nil];
		//[NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking
	}

	context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
	assert(context);
	int ret = [EAGLContext setCurrentContext:context];
	assert(ret);
	/*if (!context || ![EAGLContext setCurrentContext:context])
	{
		[self release];
		return nil;
	}*/
	Base::mainContext = context;
	
	Base::displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(drawView)];
	//displayLink.paused = YES;
	Base::displayLinkActive = YES;
	[Base::displayLink setFrameInterval:1];
	[Base::displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	
	[EAGLContext setCurrentContext:context];
	//[self destroyFramebuffer];
	[self createFramebuffer];

	//[self drawView];

	return self;
}

#ifdef CONFIG_BASE_IPHONE_NIB
// Init from NIB
- (id)initWithCoder:(NSCoder*)coder
{
	if ((self = [super initWithCoder:coder]))
	{
		self = [self initGLES];
	}
	return self;
}
#endif

// Init from code
-(id)initWithFrame:(CGRect)frame
{
	logMsg("entered initWithFrame");
	if((self = [super initWithFrame:frame]))
	{
		self = [self initGLES];
	}
	logMsg("exiting initWithFrame");
	return self;
}

- (void)drawView
{
	/*TimeSys now;
	now.setTimeNow();
	logMsg("frame time stamp %f, duration %f, now %f", displayLink.timestamp, displayLink.duration, (float)now);*/
	//[EAGLContext setCurrentContext:context];
	//glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
	if(unlikely(!Base::displayLinkActive))
		return;

	//logMsg("screen update");
	Base::runEngine(Base::displayLink.timestamp);
	if(!Base::gfxUpdate)
	{
		Base::stopAnimation();
	}
}


- (void)layoutSubviews
{
	logMsg("in layoutSubviews");
	[self drawView];
	//logMsg("exiting layoutSubviews");
}


- (BOOL)createFramebuffer
{
	logMsg("creating OpenGL framebuffers");
    glGenFramebuffersOES(1, &viewFramebuffer);
	glGenRenderbuffersOES(1, &viewRenderbuffer);

	glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
	glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
	[context renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:(CAEAGLLayer*)self.layer];
	glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_RENDERBUFFER_OES, viewRenderbuffer);

	glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &backingWidth);
	glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &backingHeight);

	if(Base::USE_DEPTH_BUFFER)
	{
		glGenRenderbuffersOES(1, &depthRenderbuffer);
		glBindRenderbufferOES(GL_RENDERBUFFER_OES, depthRenderbuffer);
		glRenderbufferStorageOES(GL_RENDERBUFFER_OES, GL_DEPTH_COMPONENT16_OES, backingWidth, backingHeight);
		glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES, GL_RENDERBUFFER_OES, depthRenderbuffer);
	}

	if(glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES) != GL_FRAMEBUFFER_COMPLETE_OES)
	{
		logMsg("failed to make complete framebuffer object %x", glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES));
		return NO;
	}
	
	Base::openglViewIsInit = 1;
	return YES;
}


- (void)destroyFramebuffer
{
	logMsg("deleting OpenGL framebuffers");
	glDeleteFramebuffersOES(1, &viewFramebuffer);
	viewFramebuffer = 0;
	glDeleteRenderbuffersOES(1, &viewRenderbuffer);
	viewRenderbuffer = 0;

	if(depthRenderbuffer)
	{
		glDeleteRenderbuffersOES(1, &depthRenderbuffer);
		depthRenderbuffer = 0;
	}
	
	Base::openglViewIsInit = 0;
}

- (void)dealloc
{
	if ([EAGLContext currentContext] == context)
	{
		[EAGLContext setCurrentContext:nil];
	}

	[context release];
	[super dealloc];
}

#ifdef CONFIG_INPUT

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	using namespace Base;
	using namespace Input;
	for(UITouch* touch in touches)
	{
		iterateTimes((uint)Input::maxCursors, i) // find a free touch element
		{
			if(Input::m[i].touch == nil)
			{
				auto &p = Input::m[i];
				p.touch = touch;
				CGPoint startTouchPosition = [touch locationInView:self];
				auto pos = pointerPos(startTouchPosition.x * pointScale, startTouchPosition.y * pointScale);
				p.s.inWin = 1;
				p.dragState.pointerEvent(Input::Pointer::LBUTTON, PUSHED, pos);
				Input::onInputEvent(Input::Event(i, Event::MAP_POINTER, Input::Pointer::LBUTTON, PUSHED, pos.x, pos.y, true, nullptr));
				break;
			}
		}
	}
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	using namespace Base;
	using namespace Input;
	for(UITouch* touch in touches)
	{
		iterateTimes((uint)Input::maxCursors, i) // find the touch element
		{
			if(Input::m[i].touch == touch)
			{
				auto &p = Input::m[i];
				CGPoint currentTouchPosition = [touch locationInView:self];
				auto pos = pointerPos(currentTouchPosition.x * pointScale, currentTouchPosition.y * pointScale);
				p.dragState.pointerEvent(Input::Pointer::LBUTTON, MOVED, pos);
				Input::onInputEvent(Input::Event(i, Event::MAP_POINTER, Input::Pointer::LBUTTON, MOVED, pos.x, pos.y, true, nullptr));
				break;
			}
		}
	}
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	using namespace Base;
	using namespace Input;
	for(UITouch* touch in touches)
	{
		iterateTimes((uint)Input::maxCursors, i) // find the touch element
		{
			if(Input::m[i].touch == touch)
			{
				auto &p = Input::m[i];
				p.touch = nil;
				p.s.inWin = 0;
				CGPoint currentTouchPosition = [touch locationInView:self];
				auto pos = pointerPos(currentTouchPosition.x * pointScale, currentTouchPosition.y * pointScale);
				p.dragState.pointerEvent(Input::Pointer::LBUTTON, RELEASED, pos);
				Input::onInputEvent(Input::Event(i, Event::MAP_POINTER, Input::Pointer::LBUTTON, RELEASED, pos.x, pos.y, true, nullptr));
				break;
			}
		}
	}
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
	[self touchesEnded:touches withEvent:event];
}

#if defined(CONFIG_BASE_IOS_KEY_INPUT) || defined(CONFIG_INPUT_ICADE)
- (BOOL)canBecomeFirstResponder { return YES; }

- (BOOL)hasText { return NO; }

- (void)insertText:(NSString *)text
{
	#ifdef CONFIG_INPUT_ICADE
	if(Base::iCade.isActive())
		Base::iCade.insertText(text);
	#endif
	//logMsg("got text %s", [text cStringUsingEncoding: NSUTF8StringEncoding]);
}

- (void)deleteBackward { }

#ifdef CONFIG_INPUT_ICADE
- (UIView*)inputView
{
	return Base::iCade.dummyInputView;
}
#endif
#endif // defined(CONFIG_BASE_IOS_KEY_INPUT) || defined(CONFIG_INPUT_ICADE)

#endif

@end

@implementation MainApp

#if defined(CONFIG_INPUT) && defined(IPHONE_VKEYBOARD)
/*- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text
{
	if (textView.text.length >= 127 && range.length == 0)
	{
		logMsg("not changing text");
		return NO;
	}
	return YES;
}

- (void)textViewDidEndEditing:(UITextView *)textView
{
	logMsg("editing ended");
	Input::finishSysTextInput();
}*/

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
	logMsg("pushed return");
	[textField resignFirstResponder];
	return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
	using namespace Input;
	logMsg("editing ended");
	//inVKeyboard = 0;
	auto delegate = vKeyboardTextDelegate;
	vKeyboardTextDelegate = {};
	char text[256];
	string_copy(text, [textField.text UTF8String]);
	[textField removeFromSuperview];
	vkbdField = nil;
	if(delegate)
	{
		logMsg("running text entry callback");
		delegate(text);
	}
}

#endif

#if 0
- (void)keyboardWasShown:(NSNotification *)notification
{
	return;
	using namespace Base;
	#ifndef NDEBUG
	CGSize keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;
	logMsg("keyboard shown with size %d", (int)keyboardSize.height * pointScale);
	int visibleY = IG::max(1, int(mainWin.rect.y2 - keyboardSize.height * pointScale));
	float visibleFraction = visibleY / mainWin.rect.y2;
	/*if(isIPad)
		Gfx::viewMMHeight_ = 197. * visibleFraction;
	else
		Gfx::viewMMHeight_ = 75. * visibleFraction;*/
	//generic_resizeEvent(mainWin.rect.x2, visibleY);
	#endif
	displayNeedsUpdate();
}

- (void) keyboardWillHide:(NSNotification *)notification
{
	return;
	using namespace Base;
	logMsg("keyboard hidden");
	displayNeedsUpdate();
}
#endif

/*- (void) screenDidConnect:(NSNotification *)aNotification
{
	logMsg("New screen connected");
	UIScreen *screen = [aNotification object];
	UIScreenMode *mode = [[screen availibleModes] lastObject];
	screen.currentMode = mode;
	if(!externalWindow)
	{
		externalWindow = [UIWindow alloc];
	}
	CGRect rect = CGRectMake(0, 0, mode.size.width, mode.size.height);
	[externalWindow initWithFrame:rect];
	externalWindow.screen = screen;
	[externalWindow makeKeyAndVisible];
}
 
- (void) screenDidDisconnect:(NSNotification *)aNotification
{
	logMsg("Screen dis-connected");
}
 
- (void) screenModeDidChange:(NSNotification *)aNotification
{
	UIScreen *screen = [aNotification object];
	logMsg("Screen-mode change"); // [screen currentMode]
}*/

static uint iOSOrientationToGfx(UIDeviceOrientation orientation)
{
	switch(orientation)
	{
		case UIDeviceOrientationPortrait: return Gfx::VIEW_ROTATE_0;
		case UIDeviceOrientationLandscapeLeft: return Gfx::VIEW_ROTATE_90;
		case UIDeviceOrientationLandscapeRight: return Gfx::VIEW_ROTATE_270;
		case UIDeviceOrientationPortraitUpsideDown: return Gfx::VIEW_ROTATE_180;
		default : return 255; // TODO: handle Face-up/down
	}
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	using namespace Base;
	NSString *currSysVer = [[UIDevice currentDevice] systemVersion];
	#ifndef NDEBUG
	//logMsg("in didFinishLaunchingWithOptions(), UUID %s", [[[UIDevice currentDevice] uniqueIdentifier] cStringUsingEncoding: NSASCIIStringEncoding]);
	logMsg("iOS version %s", [currSysVer cStringUsingEncoding: NSASCIIStringEncoding]);
	#endif
	mainApp = self;
	
	// unused for now since ARMv7 build now requires 4.3
	/*NSString *reqSysVer = @"4.0";
	if ([currSysVer compare:reqSysVer options:NSNumericSearch] != NSOrderedAscending)
	{
		//logMsg("enabling iOS 4 features");
		usingiOS4 = 1;
	}*/
	
	/*if ([currSysVer compare:@"3.2" options:NSNumericSearch] != NSOrderedAscending)
	{
		logMsg("enabling iOS 3.2 external display features");
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		[center addObserver:self selector:@selector(screenDidConnect:) name:UIScreenDidConnectNotification object:nil];
		[center addObserver:self selector:@selector(screenDidDisconnect:) name:UIScreenDidDisconnectNotification object:nil];
		[center addObserver:self selector:@selector(screenModeDidChange:) name:UIScreenModeDidChangeNotification object:nil];
	}*/
	
	// TODO: get real DPI if possible
	// based on iPhone/iPod DPI of 163 (326 retina)
	uint unscaledDPI = 163;
	#if !defined(__ARM_ARCH_6K__) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= 30200)
	if(isIPad)
	{
		// based on iPad DPI of 132 (264 retina) 
		unscaledDPI = 132;
		
		/*rotateView = preferedOrientation = iOSOrientationToGfx([[UIDevice currentDevice] orientation]);
		logMsg("started in %s orientation", Gfx::orientationName(rotateView));
		#ifdef CONFIG_INPUT
		Gfx::configureInputForOrientation();
		#endif*/
	}
	#endif
    
    CGRect rect = [[UIScreen mainScreen] bounds];
    
    if ([[UIScreen mainScreen] respondsToSelector:@selector(fixedCoordinateSpace)])
    {
        rect = [[UIScreen mainScreen].fixedCoordinateSpace convertRect:[UIScreen mainScreen].bounds fromCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
    }

	mainWin.w = mainWin.rect.x2 = rect.size.width;
	mainWin.h = mainWin.rect.y2 = rect.size.height;
	Gfx::viewMMWidth_ = std::round((mainWin.w / (float)unscaledDPI) * 25.4);
	Gfx::viewMMHeight_ = std::round((mainWin.h / (float)unscaledDPI) * 25.4);
	logMsg("set screen MM size %dx%d", Gfx::viewMMWidth_, Gfx::viewMMHeight_);
	currWin = mainWin;
	// Create a full-screen window
	devWindow = [[UIWindow alloc] initWithFrame:rect];
	
	#ifdef GREYSTRIPE
	initGS(self);
	#endif
	
	NSNotificationCenter *nCenter = [NSNotificationCenter defaultCenter];
	[nCenter addObserver:self selector:@selector(orientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];
	//[nCenter addObserver:self selector:@selector(keyboardWasShown:) name:UIKeyboardDidShowNotification object:nil];
	//[nCenter addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
	
	// Create the OpenGL ES view and add it to the Window
	glView = [[EAGLView alloc] initWithFrame:rect];
	#ifdef CONFIG_INPUT_ICADE
	iCade.init(glView);
	#endif
	Base::engineInit();
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
	Base::setAutoOrientation(1);

	// view controller init
	if(usingiOS4)
	{
		viewCtrl = [[ImagineUIViewController alloc] init];
		viewCtrl.view = glView;
		[glView release];
		devWindow.rootViewController = viewCtrl;
		[viewCtrl release];
	}
	else
	{
		[devWindow addSubview:glView];
		[glView release];
	}

	[devWindow makeKeyAndVisible];
	logMsg("exiting didFinishLaunchingWithOptions");
	return YES;
}

- (void)orientationChanged:(NSNotification *)notification
{
	uint o = iOSOrientationToGfx([[UIDevice currentDevice] orientation]);
	if(o == 255)
		return;
	if(o == Gfx::VIEW_ROTATE_180 && !Base::isIPad)
		return; // ignore upside-down orientation unless using iPad
	logMsg("new orientation %s", Gfx::orientationName(o));
	Gfx::preferedOrientation = o;
	Gfx::setOrientation(Gfx::preferedOrientation);
}

- (void)applicationWillResignActive:(UIApplication *)application
{
	logMsg("resign active");
	Base::stopAnimation();
	glFinish();
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	using namespace Base;
	logMsg("became active");
	if(!Base::openglViewIsInit)
		[glView createFramebuffer];
	Base::appState = APP_RUNNING;
	if(Base::displayLink)
		Base::startAnimation();
	Base::onResume(1);
	#ifdef CONFIG_INPUT_ICADE
	iCade.didBecomeActive();
	#endif
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	using namespace Base;
	logMsg("app exiting");
	//Base::stopAnimation();
	Base::appState = APP_EXITING;
	Base::onExit(0);
	logMsg("app exited");
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	using namespace Base;
	logMsg("entering background");
	appState = APP_PAUSED;
	Base::stopAnimation();
	Base::onExit(1);
	#ifdef CONFIG_INPUT_ICADE
	iCade.didEnterBackground();
	#endif
	glFinish();
	[glView destroyFramebuffer];
	logMsg("entered background");
}

- (void)timerCallback:(id)callback
{
	using namespace Base;
	logMsg("running callback");
	NSData *callbackData = (NSData*)callback;
	CallbackDelegate del;
	[callbackData getBytes:&del length:sizeof(del)];
	del();
}

- (void)handleThreadMessage:(NSValue *)arg
{
	using namespace Base;
	ThreadMsg msg;
	[arg getValue:&msg];
	processAppMsg(msg.type, msg.shortArg, msg.intArg, msg.intArg2);
}

- (void)dealloc
{
	[Base::devWindow release];
	//[glView release]; // retained in devWindow
	[super dealloc];
}

@end

namespace Base
{

void nsLog(const char* str)
{
	NSLog(@"%s", str);
}

void nsLogv(const char* format, va_list arg)
{
	auto formatStr = [[NSString alloc] initWithBytesNoCopy:(void*)format length:strlen(format) encoding:NSUTF8StringEncoding freeWhenDone:false];
	NSLogv(formatStr, arg);
	[formatStr release];
}

void setVideoInterval(uint interval)
{
	logMsg("setting frame interval %d", (int)interval);
	assert(interval >= 1);
	[Base::displayLink setFrameInterval:interval];
}

static void setViewportForStatusbar(UIApplication *sharedApp)
{
	using namespace Gfx;
	mainWin.rect.x = mainWin.rect.y = 0;
	mainWin.rect.x2 = mainWin.w;
	mainWin.rect.y2 = mainWin.h;
	//logMsg("status bar hidden %d", sharedApp.statusBarHidden);
	if(!sharedApp.statusBarHidden)
	{
		bool isSideways = rotateView == VIEW_ROTATE_90 || rotateView == VIEW_ROTATE_270;
		auto statusBarHeight = (isSideways ? sharedApp.statusBarFrame.size.width : sharedApp.statusBarFrame.size.height) * pointScale;
		if(isSideways)
		{
			if(rotateView == VIEW_ROTATE_270)
				mainWin.rect.x = statusBarHeight;
			else
				mainWin.rect.x2 -= statusBarHeight;
		}
		else
		{
			mainWin.rect.y = statusBarHeight;
		}
		logMsg("status bar height %d", (int)statusBarHeight);
		logMsg("adjusted window to %d:%d:%d:%d", mainWin.rect.x, mainWin.rect.y, mainWin.rect.x2, mainWin.rect.y2);
	}
}

void setStatusBarHidden(uint hidden)
{
	auto sharedApp = [UIApplication sharedApplication];
	assert(sharedApp);
	#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 30200
		[sharedApp setStatusBarHidden: hidden ? YES : NO withAnimation: UIStatusBarAnimationFade];
	#else
		[sharedApp setStatusBarHidden: hidden ? YES : NO animated:YES];
	#endif
	setViewportForStatusbar(sharedApp);
	generic_resizeEvent(mainWin);
}

static UIInterfaceOrientation gfxOrientationToUIInterfaceOrientation(uint orientation)
{
	using namespace Gfx;
	switch(orientation)
	{
		default: return UIInterfaceOrientationPortrait;
		case VIEW_ROTATE_270: return UIInterfaceOrientationLandscapeLeft;
		case VIEW_ROTATE_90: return UIInterfaceOrientationLandscapeRight;
		case VIEW_ROTATE_180: return UIInterfaceOrientationPortraitUpsideDown;
	}
}

void setSystemOrientation(uint o)
{
	using namespace Input;
	if(vKeyboardTextDelegate) // TODO: allow orientation change without aborting text input
	{
		logMsg("aborting active text input");
		vKeyboardTextDelegate(nullptr);
		vKeyboardTextDelegate = {};
	}
	auto sharedApp = [UIApplication sharedApplication];
	assert(sharedApp);
	[sharedApp setStatusBarOrientation:gfxOrientationToUIInterfaceOrientation(o) animated:YES];
	setViewportForStatusbar(sharedApp);
}

static bool autoOrientationState = 0; // Turned on in applicationDidFinishLaunching

void setAutoOrientation(bool on)
{
	if(autoOrientationState == on)
		return;
	autoOrientationState = on;
	logMsg("set auto-orientation: %d", on);
	if(on)
		[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
	else
	{
		Gfx::preferedOrientation = Gfx::rotateView;
		[[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
	}
}

void exitVal(int returnVal)
{
	appState = APP_EXITING;
	onExit(0);
	::exit(returnVal);
}
void abort() { ::abort(); }

void displayNeedsUpdate()
{
	generic_displayNeedsUpdate();
	if(appState == APP_RUNNING && Base::displayLinkActive == NO)
	{
		Base::startAnimation();
	}
}

void openURL(const char *url)
{
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:
		[NSString stringWithCString:url encoding:NSASCIIStringEncoding]]];
}

void setIdleDisplayPowerSave(bool on)
{
	auto sharedApp = [UIApplication sharedApplication];
	assert(sharedApp);
	sharedApp.idleTimerDisabled = on ? NO : YES;
	logMsg("set idleTimerDisabled %d", (int)sharedApp.idleTimerDisabled);
}

void sendMessageToMain(ThreadPThread &, int type, int shortArg, int intArg, int intArg2)
{
	ThreadMsg msg = { (int16)type, (int16)shortArg, intArg, intArg2 };
	NSValue *arg = [[NSValue alloc] initWithBytes:&msg objCType:@encode(Base::ThreadMsg)];
	[mainApp performSelectorOnMainThread:@selector(handleThreadMessage:)
		withObject:arg
		waitUntilDone:NO];
	[arg release];
}

static const char *docPath = 0;

const char *documentsPath()
{
	if(!docPath)
	{
		#ifdef CONFIG_BASE_IOS_JB
			return "/User/Library/Preferences";
		#else
			NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
			NSString *documentsDirectory = [paths objectAtIndex:0];
			docPath = strdup([documentsDirectory cStringUsingEncoding: NSASCIIStringEncoding]);
		#endif
	}
	return docPath;
}

const char *storagePath()
{
	#ifdef CONFIG_BASE_IOS_JB
		return "/User/Media";
	#else
		return documentsPath();
	#endif
}

bool deviceIsIPad()
{
	return isIPad;
}

#ifdef CONFIG_BASE_IOS_SETUID

uid_t realUID = 0, effectiveUID = 0;
static void setupUID()
{
	realUID = getuid();
	effectiveUID = geteuid();
	seteuid(realUID);
}

void setUIDReal()
{
	seteuid(Base::realUID);
}

bool setUIDEffective()
{
	return seteuid(Base::effectiveUID) == 0;
}

#endif

bool supportsFrameTime()
{
	return true;
}

void setWindowPixelBestColorHint(bool best)
{
	assert(!mainContext); // should only call before initial window is created
	useMaxColorBits = best;
}

bool windowPixelBestColorHintDefault()
{
	return Config::MACHINE_IS_GENERIC_ARMV7;
}

}

#ifdef CONFIG_INPUT_ICADE

namespace Input
{

void Device::setICadeMode(bool on)
{
	if(map_ == Input::Event::MAP_ICADE) // BT Keyboard always treated as iCade
	{
		logMsg("set iCade mode %s for %s", on ? "on" : "off", name());
		iCadeMode_ = on;
		Base::iCade.setActive(on);
	}
	else if(on)
		logWarn("tried to set iCade mode on device with map %d", map_);
}

}

#endif

double TimeMach::timebaseNSec = 0, TimeMach::timebaseUSec = 0,
	TimeMach::timebaseMSec = 0, TimeMach::timebaseSec = 0;

int main(int argc, char *argv[])
{
	using namespace Base;
	#ifdef CONFIG_BASE_IOS_SETUID
	setupUID();
	#endif
	
	doOrExit(logger_init());
	TimeMach::setTimebase();
	
	#ifdef CONFIG_BASE_IOS_SETUID
	logMsg("real UID %d, effective UID %d", realUID, effectiveUID);
	if(access("/Library/MobileSubstrate/DynamicLibraries/Backgrounder.dylib", F_OK) == 0)
	{
		logMsg("manually loading Backgrounder.dylib");
		dlopen("/Library/MobileSubstrate/DynamicLibraries/Backgrounder.dylib", RTLD_LAZY | RTLD_GLOBAL);
	}
	/*if(access("/Library/MobileSubstrate/DynamicLibraries/Blutrol.dylib", F_OK) == 0)
	{
		logMsg("manually loading Blutrol.dylib");
		dlopen("/Library/MobileSubstrate/DynamicLibraries/Blutrol.dylib", RTLD_LAZY | RTLD_GLOBAL);
	}*/
	#endif

	#ifdef CONFIG_FS
	FsPosix::changeToAppDir(argv[0]);
	#endif
	
	#if !defined(__ARM_ARCH_6K__) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= 30200)
	if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
	{
		isIPad = 1;
		logMsg("running on iPad");
	}
	#endif
	
	#ifdef CONFIG_INPUT
	doOrExit(Input::init());
	#endif
	
	#ifdef CONFIG_AUDIO
	Audio::initSession();
	#endif

	Base::grayColorSpace = CGColorSpaceCreateDeviceGray();
	Base::rgbColorSpace = CGColorSpaceCreateDeviceRGB();

	doOrExit(onInit(argc, argv));

	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	UIApplicationMain(argc, argv, nil, @"MainApp");
	//[pool release];
	return 0;
}
