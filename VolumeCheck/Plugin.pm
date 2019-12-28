package Plugins::VolumeCheck::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::VolumeCheck::PlayerSettings;

my $CHECK_PERIOD = 8;
my $CHECK_INTERVAL = 0.5;
my $VOLUME_CHECK_TIME = 25*60;
my $VOLUME_MAX_HISTORY = 24*60*60;
my $HIGH_VOLUME = 95;
my $DEF_VOLUME = 30;

my $log = Slim::Utils::Log->addLogCategory({
    'category' => 'plugin.volumecheck',
    'defaultLevel' => 'ERROR',
    'description' => 'PLUGIN_VOLUMECHECK'
});

my $prefs = preferences('plugin.volumecheck');
my $serverPrefs = preferences('server');

sub getDisplayName {
    return 'PLUGIN_VOLUMECHECK';
}

my @browseMenuChoices = (
    'PLUGIN_VOLUMECHECK_ENABLE',
);
my %menuSelection;

my %defaults = (
    'enabled' => 0,
);

my $callbackSet = 0;
my $originalMixerVolumeCommand;
my $originalPlayCommand;
my $originalPauseCommand;
my $originalPlayistcontrolCommand;
my $originalPowerCommand;
my $pluginEnabled = 0;
my %playerVolumes;

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);
    Plugins::VolumeCheck::PlayerSettings->new();

    if ( $callbackSet == 0 ) {
        $originalMixerVolumeCommand = Slim::Control::Request::addDispatch(['mixer', 'volume', '_newvalue'],[1, 0, 1, \&VolumeCheck_mixerVolumeCommand]);
        $originalPlayCommand = Slim::Control::Request::addDispatch(['play', '_fadeIn'], [1, 0, 1, \&VolumeCheck_playCommand]);
        $originalPauseCommand = Slim::Control::Request::addDispatch(['pause'], [1, 0, 0, \&VolumeCheck_pauseCommand]);
        $originalPlayistcontrolCommand = Slim::Control::Request::addDispatch(['playlistcontrol'], [1, 0, 1, \&VolumeCheck_playlistcontrolCommand]);
        $originalPowerCommand = Slim::Control::Request::addDispatch(['power', '_newvalue', '_noplay'], [1, 0, 1, \&VolumeCheck_powerCommand]);
        $callbackSet = 1;
    }
    $pluginEnabled = 1;
}

sub shutdownPlugin {
    $pluginEnabled = 0;
}

sub VolumeCheck_mixerVolumeCommand {
    my @args = @_;
    if ($pluginEnabled == 1) {
        my $request = $args[0];
        my $client = $request->client();
        my $currentVolume = $serverPrefs->client($client)->get("volume");
        my $newVolume = $request->getParam('_newvalue');
        $log->debug("[" . $client->id . "] " . $currentVolume . " -> " . $newVolume);
        if ($newVolume>=$HIGH_VOLUME && $currentVolume<=($HIGH_VOLUME-20)) {
            $log->debug("[" . $client->id . "] Resetting to: " . $currentVolume);
            $client->execute(['mixer', 'volume', $currentVolume]);
            Slim::Utils::Timers::killTimers($client, \&VolumeCheck_resetVolume);
            Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.05, \&VolumeCheck_resetVolume);
            $request->setStatusDone;
            return;
        }

        if (exists($playerVolumes{$client->id})) {
            $playerVolumes{$client->id}{'level'} = $newVolume;
        }
    }

    return &$originalMixerVolumeCommand(@args);
}

sub VolumeCheck_resetVolume {
    my $client = shift;
    my $currentVolume = $serverPrefs->client($client)->get("volume");
    $log->debug("[" . $client->id . "] " . $currentVolume);
    $client->execute(['mixer', 'volume', $currentVolume]);
}

sub VolumeCheck_startChecker {
    if ($pluginEnabled == 1) {
        my $request = shift;
        my $command = shift;
        my $client = $request->client();
        my $now = time();

        $log->debug("[" . $client->id . "] " . $command);
        # If more than 25 minutes since last power/play/playlistcontrol, ensure no volume changes...
        if (!exists($playerVolumes{$client->id}) || $command eq "power" || ($now-$playerVolumes{$client->id}{'time'}) >= $VOLUME_CHECK_TIME || ($now-$playerVolumes{$client->id}{'time'}) <= 2) {
            my $level = $serverPrefs->client($client)->get("volume");
            if ($level >= $HIGH_VOLUME) {
                $level = $DEF_VOLUME;
            }
            $log->debug("[" . $client->id . "] Start volume checker, level: " . $level);
            $playerVolumes{$client->id} = { 'time' => $now, 'level' => $level };
            VolumeCheck_setVolume($client);
        }

        # Clean up old history (to handle removed players, etc.)
        my @toClear = ();
        for my $id (keys %playerVolumes) {
            if (($now - $playerVolumes{$id}{'time'}) >= $VOLUME_MAX_HISTORY) {
                push @toClear, $id;
            }
        }
        foreach my $id (@toClear) {
            $log->debug("Remove state for ". $id);
            delete($playerVolumes{$id});
        }
    }
}

sub VolumeCheck_setVolume {
    my $client = shift;
    my $now = time();
    my $time = $playerVolumes{$client->id}{'time'};

    if ( ($now - $time) <= $CHECK_PERIOD) {
        $log->debug("[" . $client->id . "] " . $playerVolumes{$client->id}{'level'});
        $client->execute(['mixer', 'volume', $playerVolumes{$client->id}{'level'}]);
        Slim::Utils::Timers::killTimers($client, \&VolumeCheck_setVolume);
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $CHECK_INTERVAL, \&VolumeCheck_setVolume);
    }
}

sub VolumeCheck_playCommand {
    my @args = @_;
    VolumeCheck_startChecker($args[0], "play");
    return &$originalPlayCommand(@args);
}

sub VolumeCheck_pauseCommand {
    my @args = @_;
    VolumeCheck_startChecker($args[0], "pause");
    return &$originalPauseCommand(@args);
}

sub VolumeCheck_playlistcontrolCommand {
    my @args = @_;
    VolumeCheck_startChecker($args[0], "playlistcontrol");
    return &$originalPlayistcontrolCommand(@args);
}

sub VolumeCheck_powerCommand {
    my @args = @_;
    my $request = $args[0];
    my $client   = $request->client();
    my $newpower = $request->getParam('_newvalue');
    if (!defined $newpower) {
        $newpower = $client->power() ? 0 : 1;
    }

    if ($newpower != $client->power() && 1==$newpower) {
        VolumeCheck_startChecker($args[0], "power");
    }

    return &$originalPowerCommand(@args);
}

sub lines {
    my $client = shift;
    my ($line1, $line2, $overlay2);
    my $flag;

    $line1 = $client->string('PLUGIN_VOLUMECHECK') . " (" . ($menuSelection{$client}+1) . " " . $client->string('OF') . " " . ($#browseMenuChoices + 1) . ")";
    $line2 = $client->string($browseMenuChoices[$menuSelection{$client}]);

    # Add a checkbox
    if ($browseMenuChoices[$menuSelection{$client}] eq 'PLUGIN_VOLUMECHECK_ENABLE') {
        $flag  = $prefs->client($client)->get('enabled');
        $overlay2 = Slim::Buttons::Common::checkBoxOverlay($client, $flag);
    }

    return {
        'line'    => [ $line1, $line2],
        'overlay' => [undef, $overlay2],
    };
}

my %functions = (
    'up' => sub  {
        my $client = shift;
        my $newposition = Slim::Buttons::Common::scroll($client, -1, ($#browseMenuChoices + 1), $menuSelection{$client});
        $menuSelection{$client} =$newposition;
        $client->update();
    },
    'down' => sub  {
        my $client = shift;
        my $newposition = Slim::Buttons::Common::scroll($client, +1, ($#browseMenuChoices + 1), $menuSelection{$client});
        $menuSelection{$client} =$newposition;
        $client->update();
    },
    'right' => sub {
        my $client = shift;
        my $cPrefs = $prefs->client($client);
        my $selection = $menuSelection{$client};

        if ($browseMenuChoices[$selection] eq 'PLUGIN_VOLUMECHECK_ENABLE') {
            my $enabled = $cPrefs->get('enabled') || 0;
            $client->showBriefly({ 'line1' => string('PLUGIN_VOLUMECHECK'), 
                                   'line2' => string($enabled ? 'PLUGIN_VOLUMECHECK_DISABLING' : 'PLUGIN_VOLUMECHECK_ENABLING') });
            $cPrefs->set('enabled', ($enabled ? 0 : 1));
        }
    },
    'left' => sub {
        my $client = shift;
        Slim::Buttons::Common::popModeRight($client);
    },
);

sub setDefaults {
    my $client = shift;
    my $force = shift;
    my $clientPrefs = $prefs->client($client);
    $log->debug("[" . $client->id . "] Checking defaults for " . $client->name() . " Forcing: " . $force);
    foreach my $key (keys %defaults) {
        if (!defined($clientPrefs->get($key)) || $force) {
            $log->debug("Setting default value for $key: " . $defaults{$key});
            $clientPrefs->set($key, $defaults{$key});
        }
    }
}

sub getFunctions { return \%functions;}
 
1;

