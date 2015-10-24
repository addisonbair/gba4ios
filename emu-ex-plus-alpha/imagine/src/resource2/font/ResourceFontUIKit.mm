/*  This file is part of Imagine.

	Imagine is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	Imagine is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with Imagine.  If not, see <http://www.gnu.org/licenses/> */

#define thisModuleName "res:font:uikit"
#include <engine-globals.h>
#include <gfx/Gfx.hh>
#include <util/strings.h>
#include <base/iphone/private.hh>
#include "ResourceFontUIKit.hh"
#import <CoreGraphics/CGBitmapContext.h>
#import <CoreGraphics/CGContext.h>
#import <UIKit/UIKit.h>

static CGColorRef textColor = nullptr;

ResourceFont *ResourceFontUIKit::loadSystem()
{
	ResourceFontUIKit *inst = new ResourceFontUIKit;
	if(!inst)
	{
		logErr("out of memory");
		return nullptr;
	}
	
	if(!textColor)
	{
		const CGFloat component[] = { 1., 1. };
		textColor = CGColorCreate(Base::grayColorSpace, component);
	}

	return inst;
}

void ResourceFontUIKit::free ()
{
	if(pixBuffer)
		mem_free(pixBuffer);
	delete this;
}

static void renderTextIntoBuffer(NSString *str, void *buff, uint xSize, uint ySize,
		CGColorSpaceRef colorSpace, CGColorRef textColor, UIFont *font)
{
	auto context = CGBitmapContextCreate(buff, xSize, ySize, 8, xSize, colorSpace, kCGImageAlphaOnly);
	assert(context);
	CGContextSetTextDrawingMode(context, kCGTextFill);
	//CGContextSetStrokeColorWithColor(context, textColor);
	CGContextSetFillColorWithColor(context, textColor);
	CGContextTranslateCTM(context, 0.0f, ySize);
	CGContextScaleCTM(context, 1.0f, -1.0f);
	UIGraphicsPushContext(context);
	//[str drawInRect:CGRectMake(0, 0, xSize, ySize) withFont:font];
	[str drawAtPoint:CGPointMake(0, 0) withFont:font];
	UIGraphicsPopContext();
	CGContextRelease(context);
}

void ResourceFontUIKit::charBitmap(void *&data, int &x, int &y, int &pitch)
{
	if(!pixBuffer)
	{
		logMsg("re-rendering char %c", currChar);
		pixBuffer = (uchar*)mem_calloc(cXFullSize * cYFullSize);
		auto str = [[NSString alloc] initWithCharacters:&currChar length:1];
		renderTextIntoBuffer(str, pixBuffer, cXFullSize, cYFullSize,
			Base::grayColorSpace, textColor, activeFont);
	}
	data = startOfCharInPixBuffer;
	x = cXSize;
	y = cYSize;
	pitch = cXFullSize;
}

void ResourceFontUIKit::unlockCharBitmap(void *data)
{
	mem_freeSafe(pixBuffer);
	pixBuffer = nullptr;
}

CallResult ResourceFontUIKit::activeChar (int idx, GlyphMetrics &metrics)
{
	//logMsg("active char: %c", idx);
	if(currChar != (unichar)idx)
	{
		currChar = idx;
		auto str = [[NSString alloc] initWithCharacters:&currChar length:1];
		
		// measure max bounds
		CGSize size = [str sizeWithFont:activeFont];
		if(!size.width || !size.height)
		{
			logMsg("invalid char 0x%X size %f:%f", idx, size.width, size.height);
			return INVALID_PARAMETER;
		}
		//logMsg("char %c size %f:%f", idx, size.width, size.height);
		cXFullSize = size.width;
		cYFullSize = size.height;
		
		// render char into buffer
		uint bufferSize = cXFullSize * cYFullSize;
		if(pixBuffer)
			mem_free(pixBuffer);
		pixBuffer = (uchar*)mem_calloc(bufferSize);
		//pixBuffer = (uchar*)mem_realloc(pixBuffer, bufferSize);
		//mem_zero(pixBuffer, bufferSize);
		renderTextIntoBuffer(str, pixBuffer, size.width, size.height,
			Base::grayColorSpace, textColor, activeFont);
		
		// measure real bounds
		uint minX = cXFullSize, maxX = 0, minY = cYFullSize, maxY = 0;
		iterateTimes(cYFullSize, y)
			iterateTimes(cXFullSize, x)
			{
				if(pixBuffer[mem_arr2DOffsetRM(x, y, cXFullSize)])
				{
					if (x < minX) minX = x;
					if (x > maxX) maxX = x;
					if (y < minY) minY = y;
					if (y > maxY) maxY = y;
				}
			}
		//logMsg("min bounds %d:%d:%d:%d", minX, minY, maxX, maxY);
		auto cXOffset = minX;
		cXSize = (maxX - minX) + 1;
		auto cYOffset = minY;
		cYSize = (maxY - minY) + 1;
		startOfCharInPixBuffer = pixBuffer + mem_arr2DOffsetRM(cXOffset, cYOffset, cXFullSize);
		
		metrics.xSize = cXSize;
		metrics.ySize = cYSize;
		metrics.xOffset = cXOffset;
		metrics.yOffset = -cYOffset;
		metrics.xAdvance = cXFullSize;
	}
	return OK;
}

#warning Keep an eye out here...

CallResult ResourceFontUIKit::newSize (const FontSettings &settings, FontSizeRef &sizeRef)
{
	UIFont *fontInst = [UIFont systemFontOfSize:(CGFloat)settings.pixelHeight];
	sizeRef.ptr = (void *)CFBridgingRetain(fontInst);
	return OK;
}

CallResult ResourceFontUIKit::applySize (FontSizeRef &sizeRef)
{
	activeFont = (__bridge id)sizeRef.ptr;
	return OK;
}

void ResourceFontUIKit::freeSize (FontSizeRef &sizeRef)
{
	CFRelease(sizeRef.ptr);
}
