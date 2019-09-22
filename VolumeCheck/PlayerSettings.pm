package Plugins::VolumeCheck::PlayerSettings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw (string);
use Slim::Display::NoDisplay;
use Slim::Display::Display;


my $prefs = preferences('plugin.volumecheck');
my $log   = logger('plugin.volumecheck');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_VOLUMECHECK');
}

sub needsClient {
    return 1;
}

sub validFor {
    return 1;
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/VolumeCheck/settings/player.html');
}

sub prefs {
    my $class = shift;
    my $client = shift;
    return ($prefs->client($client), qw(enabled));
}

sub handler {
    my ($class, $client, $params) = @_;
    $log->debug("VolumeCheck->handler() called. " . $client->name());
    #Plugins::VolumeCheck->extSetDefaults($client, 0);
    if ($params->{'saveSettings'}) {
        $params->{'pref_enabled'} = 0 unless defined $params->{'pref_enabled'};
    }

    return $class->SUPER::handler( $client, $params );
}

1;
