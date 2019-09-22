package Plugins::VolumeCheck::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::VolumeCheck::PlayerSettings;

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
my $pluginEnabled = 0;

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);
    Plugins::VolumeCheck::PlayerSettings->new();

    if ( $callbackSet == 0 ) {
        $originalMixerVolumeCommand = Slim::Control::Request::addDispatch(['mixer', 'volume', '_newvalue'],[1, 0, 1, \&VolumeCheck_mixerVolumeCommand]);
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
    my $request = $args[0];
    my $client = $request->client();
    if ($pluginEnabled == 1) {
        my $newvalue = $request->getParam('_newvalue');
        $log->debug("Volme request " . $newvalue);
        if ($newvalue>=95) {
            my $currentVolume = $serverPrefs->client($client)->get("volume");
            $log->debug("Volume request " . $currentVolume);
            if ($currentVolume<=80) {
                $request->setStatusDone;
                $log->debug("Volume request jump too large!");
                $client->execute(['mixer', 'volume', $currentVolume]);
                Slim::Utils::Timers::killTimers($client, \&resetVolume);
                Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.05, \&VolumeCheck_resetVolume);
                return;
            }
        }
    }

    $log->debug("calling original mixer function\n");
    return &$originalMixerVolumeCommand(@args);
}

sub VolumeCheck_resetVolume {
    my $client = shift;
    my $currentVolume = $serverPrefs->client($client)->get("volume");
    $log->debug("Volume resetting to " . $currentVolume);
    $client->execute(['mixer', 'volume', $currentVolume]);
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

