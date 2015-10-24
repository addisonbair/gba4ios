/*  This file is part of GBA.emu.

	PCE.emu is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	PCE.emu is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with PCE.emu.  If not, see <http://www.gnu.org/licenses/> */

#define thisModuleName "main"
#include <logger/interface.h>
#include <util/area2.h>
#include <gfx/GfxSprite.hh>
#include <audio/Audio.hh>
#include <fs/sys.hh>
#include <io/sys.hh>
#include <gui/View.hh>
#include <util/strings.h>
#include <util/time/sys.hh>
#include <EmuSystem.hh>
#include <CommonFrameworkIncludes.hh>
#include <main/Main.hh>
#include <main/Cheats.hh>
#include <vbam/gba/GBA.h>
#include <vbam/gba/Sound.h>
#include <vbam/gba/RTC.h>
#include <vbam/common/SoundDriver.h>
#include <vbam/common/Patch.h>
#include <vbam/Util.h>
void setGameSpecificSettings(GBASys &gba);
void CPULoop(GBASys &gba, bool renderGfx, bool processGfx, bool renderAudio);
void CPUCleanUp();
bool CPUReadBatteryFile(GBASys &gba, const char *);
bool CPUWriteBatteryFile(GBASys &gba, const char *);
bool CPUReadState(GBASys &gba, const char *);
bool CPUWriteState(GBASys &gba, const char *);

bool isGBAROM = false;

bool useCustomSavePath = false;
extern const char *customSavePath();

const char *creditsViewStr = "(c) 2012-2013\nRobert Broglia\nwww.explusalpha.com\n\nPortions (c) the\nVBA-m Team\nvba-m.com";
const uint EmuSystem::maxPlayers = 1;
uint EmuSystem::aspectRatioX = 3, EmuSystem::aspectRatioY = 2;
#include "CommonGui.hh"

// controls

enum
{
	gbaKeyIdxUp = EmuControls::systemKeyMapStart,
	gbaKeyIdxRight,
	gbaKeyIdxDown,
	gbaKeyIdxLeft,
	gbaKeyIdxLeftUp,
	gbaKeyIdxRightUp,
	gbaKeyIdxRightDown,
	gbaKeyIdxLeftDown,
	gbaKeyIdxSelect,
	gbaKeyIdxStart,
	gbaKeyIdxA,
	gbaKeyIdxB,
	gbaKeyIdxL,
	gbaKeyIdxR,
	gbaKeyIdxATurbo,
	gbaKeyIdxBTurbo,
	gbaKeyIdxAB,
	gbaKeyIdxRB,
};

namespace GbaKeyStatus
{
	static const uint A = BIT(0), B = BIT(1),
			SELECT = BIT(2), START = BIT(3),
			RIGHT = BIT(4), LEFT = BIT(5), UP = BIT(6), DOWN = BIT(7),
			R = BIT(8), L = BIT(9);
}

static uint ptrInputToSysButton(int input)
{
	using namespace GbaKeyStatus;
	switch(input)
	{
		case SysVController::F_ELEM: return A;
		case SysVController::F_ELEM+1: return B;
		case SysVController::F_ELEM+2: return L;
		case SysVController::F_ELEM+3: return R;

		case SysVController::C_ELEM: return SELECT;
		case SysVController::C_ELEM+1: return START;

		case SysVController::D_ELEM: return UP | LEFT;
		case SysVController::D_ELEM+1: return UP;
		case SysVController::D_ELEM+2: return UP | RIGHT;
		case SysVController::D_ELEM+3: return LEFT;
		case SysVController::D_ELEM+5: return RIGHT;
		case SysVController::D_ELEM+6: return DOWN | LEFT;
		case SysVController::D_ELEM+7: return DOWN;
		case SysVController::D_ELEM+8: return DOWN | RIGHT;
		default: bug_branch("%d", input); return 0;
	}
}

void updateVControllerMapping_GBA(uint player, SysVController::Map &map)
{
	using namespace GbaKeyStatus;
	map[SysVController::F_ELEM] = A;
	map[SysVController::F_ELEM+1] = B;
	map[SysVController::F_ELEM+2] = L;
	map[SysVController::F_ELEM+3] = R;

	map[SysVController::C_ELEM] = SELECT;
	map[SysVController::C_ELEM+1] = START;

	map[SysVController::D_ELEM] = UP | LEFT;
	map[SysVController::D_ELEM+1] = UP;
	map[SysVController::D_ELEM+2] = UP | RIGHT;
	map[SysVController::D_ELEM+3] = LEFT;
	map[SysVController::D_ELEM+5] = RIGHT;
	map[SysVController::D_ELEM+6] = DOWN | LEFT;
	map[SysVController::D_ELEM+7] = DOWN;
	map[SysVController::D_ELEM+8] = DOWN | RIGHT;
}

uint EmuSystem::translateInputAction_GBA(uint input, bool &turbo)
{
	using namespace GbaKeyStatus;
	turbo = 0;
	switch(input)
	{
		case gbaKeyIdxUp: return UP;
		case gbaKeyIdxRight: return RIGHT;
		case gbaKeyIdxDown: return DOWN;
		case gbaKeyIdxLeft: return LEFT;
		case gbaKeyIdxLeftUp: return UP | LEFT;
		case gbaKeyIdxRightUp: return UP | RIGHT;
		case gbaKeyIdxRightDown: return DOWN | RIGHT;
		case gbaKeyIdxLeftDown: return DOWN | LEFT;
		case gbaKeyIdxSelect: return SELECT;
		case gbaKeyIdxStart: return START;
		case gbaKeyIdxATurbo: turbo = 1;
		case gbaKeyIdxA: return A;
		case gbaKeyIdxBTurbo: turbo = 1;
		case gbaKeyIdxB: return B;
		case gbaKeyIdxL: return L;
		case gbaKeyIdxR: return R;
		case gbaKeyIdxAB: return A | B;
		case gbaKeyIdxRB: return R | B;
		default: bug_branch("%d", input);
	}
	return 0;
}

void EmuSystem::handleInputAction_GBA(uint state, uint emuKey)
{
	if(state == Input::PUSHED)
		unsetBits(P1, emuKey);
	else
		setBits(P1, emuKey);
}

enum
{
	CFGKEY_RTC_EMULATION = 256
};

Byte1Option optionRtcEmulation(CFGKEY_RTC_EMULATION, RTC_EMU_AUTO, 0, optionIsValidWithMax<2>);
bool detectedRtcGame = 0;

bool EmuSystem::readConfig_GBA(Io *io, uint key, uint readSize)
{
	switch(key)
	{
		default: return 0;
		bcase CFGKEY_RTC_EMULATION: optionRtcEmulation.readFromIO(io, readSize);
	}
	return 1;
}

void EmuSystem::writeConfig_GBA(Io *io)
{
	optionRtcEmulation.writeWithKeyIfNotDefault(io);
}

static bool isGBAExtension(const char *name)
{
	return string_hasDotExtension(name, "gba")
			|| string_hasDotExtension(name, "zip")
			|| string_hasDotExtension(name, "7z");
}

static int gbaFsFilter(const char *name, int type)
{
	return type == Fs::TYPE_DIR || isGBAExtension(name);
}

FsDirFilterFunc EmuFilePicker::defaultFsFilter;
FsDirFilterFunc EmuFilePicker::defaultBenchmarkFsFilter;

#define USE_PIX_RGB565
#ifdef USE_PIX_RGB565
static const PixelFormatDesc *pixFmt = &PixelFormatRGB565; //PixelFormatARGB1555; //PixelFormatRGB565
int systemColorDepth = 16;
int systemRedShift = 11;
int systemGreenShift = 6;
int systemBlueShift = 0;//1;
#else
static const PixelFormatDesc *pixFmt = &PixelFormatBGRA8888;
int systemColorDepth = 32;
int systemRedShift = 19;
int systemGreenShift = 11;
int systemBlueShift = 3;
#endif

void EmuSystem::initOptions_GBA()
{
	#ifndef CONFIG_BASE_ANDROID
	// optionFrameSkip.initDefault(optionFrameSkipAuto); Riley Testut // auto-frameskip default due to highly variable CPU usage
	#endif
}

void EmuSystem::resetGame_GBA()
{
	assert(gameIsRunning());
	CPUReset(gGba);
}

static char saveSlotChar(int slot)
{
	switch(slot)
	{
		case -1: return 'a';
		case 0 ... 9: return 48 + slot;
		default: bug_branch("%d", slot); return 0;
	}
}

void EmuSystem::sprintStateFilename_GBA(char *str, size_t size, int slot, const char *statePath, const char *gameName)
{
	snprintf(str, size, "%s/%s%c.sgm", statePath, gameName, saveSlotChar(slot));
}

int EmuSystem::saveState_GBA()
{
	FsSys::cPath saveStr;
	sprintStateFilename_GBA(saveStr, saveStateSlot);
	if(Config::envIsIOSJB)
		fixFilePermissions(saveStr);
	if(CPUWriteState(gGba, saveStr))
		return STATE_RESULT_OK;
	else
		return STATE_RESULT_IO_ERROR;
}

int EmuSystem::loadState_GBA(int saveStateSlot)
{
	FsSys::cPath saveStr;
	sprintStateFilename_GBA(saveStr, saveStateSlot);
	if(CPUReadState(gGba, saveStr))
		return STATE_RESULT_OK;
	else
		return STATE_RESULT_IO_ERROR;
}

void EmuSystem::saveAutoState_GBA()
{
	if(gameIsRunning() && optionAutoSaveState)
	{
		FsSys::cPath saveStr;
		sprintStateFilename_GBA(saveStr, -1);
		if(Config::envIsIOSJB)
			fixFilePermissions(saveStr);
		CPUWriteState(gGba, saveStr);
	}
}

void EmuSystem::saveBackupMem_GBA()
{
	if(gameIsRunning())
	{
		logMsg("saving backup memory");
		FsSys::cPath saveStr;
        
        if (useCustomSavePath)
        {
            snprintf(saveStr, sizeof(saveStr), "%s", customSavePath());
        }
        else
        {
            snprintf(saveStr, sizeof(saveStr), "%s/%s.sav", savePath(), gameName);
        }
        
		if(Config::envIsIOSJB)
			fixFilePermissions(saveStr);
		CPUWriteBatteryFile(gGba, saveStr);
		writeCheatFile_GBA();
	}
}

bool EmuSystem::vidSysIsPAL() { return 0; }
uint EmuSystem::multiresVideoBaseX() { return 0; }
uint EmuSystem::multiresVideoBaseY() { return 0; }
bool touchControlsApplicable() { return 1; }
void EmuSystem::clearInputBuffers_GBA() { P1 = 0x03FF; }

void EmuSystem::closeSystem_GBA()
{
	assert(gameIsRunning());
	logMsg("closing game %s", gameName);
	// saveBackupMem_GBA(); Riley Testut. We save manually
	CPUCleanUp();
	detectedRtcGame = 0;
	cheatsNumber = 0; // reset cheat list
}

static bool applyGamePatches(const char *patchDir, const char *romName, u8 *rom, int &romSize)
{
	FsSys::cPath patchStr;
	string_printf(patchStr, "%s/%s.ips", patchDir, romName);
	if(FsSys::fileExists(patchStr))
	{
		logMsg("applying IPS patch: %s", patchStr);
		if(!patchApplyIPS(patchStr, &rom, &romSize))
		{
			popup.postError("Error applying IPS patch");
			return false;
		}
		return true;
	}
	string_printf(patchStr, "%s/%s.ups", patchDir, romName);
	if(FsSys::fileExists(patchStr))
	{
		logMsg("applying UPS patch: %s", patchStr);
		if(!patchApplyUPS(patchStr, &rom, &romSize))
		{
			popup.postError("Error applying UPS patch");
			return false;
		}
		return true;
	}
	string_printf(patchStr, "%s/%s.ppf", patchDir, romName);
	if(FsSys::fileExists(patchStr))
	{
		logMsg("applying UPS patch: %s", patchStr);
		if(!patchApplyPPF(patchStr, &rom, &romSize))
		{
			popup.postError("Error applying PPF patch");
			return false;
		}
		return true;
	}
	return true; // no patch found
}

int EmuSystem::loadGame_GBA(const char *path)
{
    EmuFilePicker::defaultFsFilter = gbaFsFilter;
    EmuFilePicker::defaultBenchmarkFsFilter = gbaFsFilter;
    EmuSystem::aspectRatioX = 3, EmuSystem::aspectRatioY = 2;
    
	closeGame();
	emuView.initImage(0, 240, 160);
	setupGamePaths(path);
	systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;
	soundInit();
    
	int size = CPULoadRom(gGba, fullGamePath);
	if(size == 0)
	{
		popup.postError("Error loading ROM");
		return 0;
	}
    
	setGameSpecificSettings(gGba);
	if(!applyGamePatches(savePath(), gameName, gGba.mem.rom, size))
	{
		return 0;
	}
	CPUInit(gGba, 0, 0);
	CPUReset(gGba);
	FsSys::cPath saveStr;
	
    if (useCustomSavePath)
    {
        snprintf(saveStr, sizeof(saveStr), "%s", customSavePath());
    }
    else
    {
        snprintf(saveStr, sizeof(saveStr), "%s/%s.sav", savePath(), gameName);
    }
        
	CPUReadBatteryFile(gGba, saveStr);
	readCheatFile_GBA();
	logMsg("started emu");
	return 1;
}

static void commitVideoFrame()
{
	emuView.updateAndDrawContent();
}

void systemDrawScreen()
{
	commitVideoFrame();
}

#ifdef USE_NEW_AUDIO
u16 *systemObtainSoundBuffer(uint samples, uint &buffSamples, void *&ctx)
{
	auto aBuff = Audio::getPlayBuffer(samples/2);
	if(unlikely(!aBuff))
	{
		return nullptr;
	}
	buffSamples = aBuff->frames*2;
	ctx = aBuff;
	return (u16*)aBuff->data;
}

void systemCommitSoundBuffer(uint writtenSamples, void *&ctx)
{
	//logMsg("%d audio frames", writtenSamples/2);
	Audio::commitPlayBuffer((Audio::BufferContext*)ctx, writtenSamples/2);
}
#else
void systemOnWriteDataToSoundBuffer(const u16 * finalWave, int length)
{
	//logMsg("%d audio frames", Audio::pPCM.bytesToFrames(length));
	Audio::writePcm((uchar*)finalWave, EmuSystem::pcmFormat.bytesToFrames(length));
}
#endif

void EmuSystem::runFrame_GBA(bool renderGfx, bool processGfx, bool renderAudio)
{
	CPULoop(gGba, renderGfx, processGfx, renderAudio);
}

namespace Input
{

void onInputEvent_GBA(const Input::Event &e)
{
	handleInputEvent(e);
}

}

void EmuSystem::configAudioRate_GBA()
{
	logMsg("set audio rate %d", (int)optionSoundRate);
	pcmFormat.rate = optionSoundRate;
	soundSetSampleRate(gGba, optionSoundRate *.9954);
}

void EmuSystem::savePathChanged_GBA() { }

namespace Base
{

void onAppMessage_GBA(int type, int shortArg, int intArg, int intArg2) { }

CallResult onInit_GBA(int argc, char** argv)
{
	mainInitCommon();
	emuView.initPixmap((uchar*)gGba.lcd.pix, pixFmt, 240, 160);
	utilUpdateSystemColorMaps(0);
	return OK;
}

CallResult onWindowInit_GBA()
{
	static const Gfx::LGradientStopDesc navViewGrad[] =
	{
		{ .0, VertexColorPixelFormat.build(.5, .5, .5, 1.) },
		{ .03, VertexColorPixelFormat.build(42./255., 82./255., 190./255., 1.) },
		{ .3, VertexColorPixelFormat.build(42./255., 82./255., 190./255., 1.) },
		{ .97, VertexColorPixelFormat.build((42./255.) * .6, (82./255.) * .6, (190./255.) * .6, 1.) },
		{ 1., VertexColorPixelFormat.build(.5, .5, .5, 1.) },
	};

	mainInitWindowCommon(navViewGrad);
	return OK;
}

}
