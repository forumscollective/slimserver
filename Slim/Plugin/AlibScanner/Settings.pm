package Slim::Plugin::AlibScanner::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.alibscanner');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ALIBSCANNER');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/AlibScanner/settings/basic.html');
}

sub prefs {
    return ($prefs, qw(enabled alibdb debugPlaceholders debugPlaceholdersVerbose anomalyChecksEnabled));
}

1;
