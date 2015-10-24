/*  This file is part of EmuFramework.

	Imagine is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	Imagine is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with EmuFramework.  If not, see <http://www.gnu.org/licenses/> */

#define thisModuleName "filePicker"
#include <FilePicker.hh>
#include <MsgPopup.hh>
#include <EmuSystem.hh>
#include <EmuOptions.hh>
#include <Recent.hh>
#include <util/gui/ViewStack.hh>
#include <gui/FSPicker/FSPicker.hh>
#include <gui/AlertView.hh>

extern bool isGBAROM;
extern ViewStack viewStack;
void startGameFromMenu();
bool isMenuDismissKey(const Input::Event &e);
extern MsgPopup popup;
Gfx::BufferImage *getArrowAsset();
Gfx::BufferImage *getXAsset();

void EmuFilePicker::init(bool highlightFirst, FsDirFilterFunc filter, bool singleDir)
{
	FSPicker::init(".", needsUpDirControl ? getArrowAsset() : 0,
			View::needsBackControl ? getXAsset() : 0, filter, singleDir);
	onSelectFile() = [this](const char* name, const Input::Event &e){GameFilePicker::onSelectFile(name, e);};
	onClose() = [this](const Input::Event &e){GameFilePicker::onClose(e);};
	if(highlightFirst && tbl.cells)
	{
		tbl.selected = 0;
	}
}

void loadGameComplete(bool tryAutoState, bool addToRecent)
{
	if(tryAutoState) {
        if (isGBAROM)
        {
            EmuSystem::loadAutoState_GBA();
        }
        else
        {
            EmuSystem::loadAutoState_GBC();
        }
    }
	if(addToRecent)
		recent_addGame();
	startGameFromMenu();
}

bool showAutoStateConfirm(const Input::Event &e)
{
	if(!(optionConfirmAutoLoadState && optionAutoSaveState))
	{
		return 0;
	}
	FsSys::cPath saveStr;
    
    if (isGBAROM)
    {
        EmuSystem::sprintStateFilename_GBA(saveStr, -1);
    }
    else
    {
        EmuSystem::sprintStateFilename_GBC(saveStr, -1);
    }
    
	
	if(FsSys::fileExists(saveStr))
	{
		FsSys::timeStr date = "";
		FsSys::mTimeAsStr(saveStr, date);
		static char msg[96] = "";
		snprintf(msg, sizeof(msg), "Auto-save state exists from:\n%s", date);
		auto &ynAlertView = *allocModalView<YesNoAlertView>();
		ynAlertView.init(msg, !e.isPointer(), "Continue", "Restart Game");
		ynAlertView.onYes() =
			[](const Input::Event &e)
			{
				loadGameComplete(true, true);
			};
		ynAlertView.onNo() =
			[](const Input::Event &e)
			{
				loadGameComplete(false, true);
			};
		View::addModalView(ynAlertView);
		return 1;
	}
	return 0;
}

void loadGameCompleteFromFilePicker(uint result, const Input::Event &e)
{
	if(!result)
		return;

	if(!showAutoStateConfirm(e))
	{
		loadGameComplete(1, 1);
	}
}

void GameFilePicker::onSelectFile(const char* name, const Input::Event &e)
{
	EmuSystem::onLoadGameComplete() =
		[](uint result, const Input::Event &e)
		{
			loadGameCompleteFromFilePicker(result, e);
		};
    
    auto res = 0;
    
    if (isGBAROM)
    {
        res = EmuSystem::loadGame_GBA(name);
    }
    else
    {
        res = EmuSystem::loadGame_GBC(name);
    }
    
	if(res == 1)
	{
		loadGameCompleteFromFilePicker(1, e);
	}
	else if(res == 0)
	{
		EmuSystem::clearGamePaths();
	}
}

void GameFilePicker::onClose(const Input::Event &e)
{
	viewStack.popAndShow();
}

void loadGameCompleteFromBenchmarkFilePicker(uint result, const Input::Event &e)
{
	if(result)
	{
		logMsg("starting benchmark");
		TimeSys time = EmuSystem::benchmark();
		EmuSystem::closeGame(0);
		logMsg("done in: %f", double(time));
		popup.printf(2, 0, "%.2f fps", double(180.)/double(time));
	}
}

void EmuFilePicker::initForBenchmark(bool highlightFirst, bool singleDir)
{
	EmuFilePicker::init(highlightFirst, defaultBenchmarkFsFilter, singleDir);
	onSelectFile() =
		[this](const char* name, const Input::Event &e)
		{
			EmuSystem::onLoadGameComplete() =
				[](uint result, const Input::Event &e)
				{
					loadGameCompleteFromBenchmarkFilePicker(result, e);
				};
			auto res = 0;
            
            if (isGBAROM)
            {
                res = EmuSystem::loadGame_GBA(name);
            }
            else
            {
                res = EmuSystem::loadGame_GBC(name);
            }
			if(res == 1)
			{
				loadGameCompleteFromBenchmarkFilePicker(1, e);
			}
			else if(res == 0)
			{
				EmuSystem::clearGamePaths();
			}
		};
	onClose() =
		[this](const Input::Event &e)
		{
			View::removeModalView();
		};
}
