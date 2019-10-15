package Plugins::VolumeCheck::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::VolumeCheck::PlayerSettings;

my $CHECK_PERIOD = 3;
my $CHECK_INTERVAL = 0.5;
my $VOLUME_CHECK_TIME = 25*60;

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
        $callbackSet = 1;
    }
    $pluginEnabled = 1;
}

sub shutdownPlugin {
    $pluginEnabled = 0;
}

sub VolumeCheck_mixerVolumeCommand {
    $log->debug("VolumeCheck_mixerVolumeCommand running\n");
    my @args = @_;
    if ($pluginEnabled == 1) {
        my $request = $args[0];
        my $client = $request->client();
        my $newvalue = $request->getParam('_newvalue');
        $log->debug("Volme request " . $newvalue);
        if ($newvalue>=95) {
            my $currentVolume = $serverPrefs->client($client)->get("volume");
            $log->debug("Volume request " . $currentVolume);
            if ($currentVolume<=80) {
                $request->setStatusDone;
                $log->debug("Volume request jump too large!");
                $client->execute(['mixer', 'volume', $currentVolume]);
                Slim::Utils::Timers::killTimers($client, \&VolumeCheck_resetVolume);
                Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.05, \&VolumeCheck_resetVolume);
                return;
            }
        }
    }

    $log->debug("Calling original mixer function\n");
    return &$originalMixerVolumeCommand(@args);
}

sub VolumeCheck_resetVolume {
    my $client = shift;
    my $currentVolume = $serverPrefs->client($client)->get("volume");
    $log->debug("Volume resetting to " . $currentVolume);
    $client->execute(['mixer', 'volume', $currentVolume]);
}

sub VolumeCheck_playCommand {
    $log->debug("VolumeCheck_playCommand running\n");
    my @args = @_;
    if ($pluginEnabled == 1) {
        my $request = $args[0];
        my $client = $request->client();
        my $now = time();

        # If more than 20 minutes since last play, ensure no volume changes...
        if (!exists($playerVolumes{$client->id}) || ($now-$playerVolumes{$client->id}{'time'}) > $VOLUME_CHECK_TIME) {
            $log->debug("Start play checker for ". $client->id . "\n");
            $playerVolumes{$client->id} = { 'time' => $now, 'level' => $serverPrefs->client($client)->get("volume") };
            Slim::Utils::Timers::killTimers($client, \&VolumeCheck_checkVolumeOnPlay);
            Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $CHECK_INTERVAL, \&VolumeCheck_checkVolumeOnPlay);
        }

        # Clean up old history (to handle removed players, etc.)
        $log->debug("Tidy state hash\n");
        my @toClear = ();
        for my $id (keys %playerVolumes) {
            if (($now - $playerVolumes{$id}{'time'}) > $VOLUME_CHECK_TIME) {
                push @toClear, $id;
            }
        }
        foreach my $id (@toClear) {
            $log->debug("Remove state for ". $id . "\n");
            delete($playerVolumes{$id});
        }
    }

    $log->debug("Calling original play function\n");
    return &$originalPlayCommand(@args);
}

sub VolumeCheck_checkVolumeOnPlay {
    my $client = shift;
    my $now = time();
    my $time = $playerVolumes{$client->id}{'time'};

    if ( ($now - $time) <= $CHECK_PERIOD) {
        $log->debug("VolumeCheck_playCommand setting volume of " . $client->id . " to " . $playerVolumes{$client->id}{'level'} . "\n");
        $client->execute(['mixer', 'volume', $playerVolumes{$client->id}{'level'}]);
        Slim::Utils::Timers::killTimers($client, \&VolumeCheck_checkVolumeOnPlay);
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $CHECK_INTERVAL, \&VolumeCheck_checkVolumeOnPlay);
    }
}

sub VolumeCheck_pauseCommand {
    $log->debug("VolumeCheck_pauseCommand running\n");
    my @args = @_;
    if ($pluginEnabled == 1) {
        my $request = $args[0];
        my $client = $request->client();
        my $now = time();

        # If more than 20 minutes since last play, ensure no volume changes...
        if (exists($playerVolumes{$client->id}) ) {
            $log->debug("Reset play checker for ". $client->id . "\n");
            $playerVolumes{$client->id}{'time'} = $now;
            Slim::Utils::Timers::killTimers($client, \&VolumeCheck_checkVolumeOnPlay);
        }
    }

    $log->debug("Calling original pause function\n");
    return &$originalPauseCommand(@args);
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
    $log->debug("Checking defaults for " . $client->name() . " Forcing: " . $force);
    foreach my $key (keys %defaults) {
        if (!defined($clientPrefs->get($key)) || $force) {
            $log->debug("Setting default value for $key: " . $defaults{$key});
            $clientPrefs->set($key, $defaults{$key});
        }
    }
}

sub getFunctions { return \%functions;}
 
1;

