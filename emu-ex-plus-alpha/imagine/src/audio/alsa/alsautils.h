#pragma once

#include <alsa/asoundlib.h>

static const char *alsaPcmStateToString(snd_pcm_state_t state)
{
	switch(state)
	{
		case SND_PCM_STATE_OPEN: return "Open";
		case SND_PCM_STATE_SETUP: return "Setup";
		case SND_PCM_STATE_PREPARED: return "Prepare";
		case SND_PCM_STATE_RUNNING: return "Running";
		case SND_PCM_STATE_XRUN: return "XRun";
		case SND_PCM_STATE_DRAINING: return "Draining";
		case SND_PCM_STATE_PAUSED: return "Paused";
		case SND_PCM_STATE_SUSPENDED: return "Suspended";
		case SND_PCM_STATE_DISCONNECTED: return "Disconnected";
		default: bug_branch("%d", state); return 0;
	}
}
