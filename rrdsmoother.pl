#!/usr/bin/perl 
#===============================================================================
#
#  FILE: rrdsmother.pl
#
#  USAGE: ./rrdsmother.pl [-d date -t time -s scale -ts peak_span --debug --analysis --] rrd_file/directory
#  Date form at yyyy-mm-dd, time format hh:mm 
#
#  DESCRIPTION: 
#   Script removes peaks on rrd graphs between specified time diapason. If some value on this diapason is 
#   significantly different (or in \"scale\" times different if scale's set) from previous and following 
#   values it's our peak and it'll be smoothered. By default scale is 10 and more.
#   Peak span is a count of value measurements peak was present. Default is equal to 1.
#   Date can be exact and can be diapason. If it's diapason then time is ignored. You can specify a standart 
#   diapason (5 days before, 5 days after) by putting '~' before exact date.
#   
#   Examples meaning the same date diapason:  
#       -d 2013-11-01 2013-11-10
#       -d ~2013-11-05
#   Example of exact date: 
#       -d 2013-11-05
#   
#   Time is always a diapason. If you specify a exact time without ~ it'll be standart diapason 15m before 
#   and after this time.
#   
#   Examples: 
#       -t 12:15
#       -t 12:15 13:00        
#   
#   !!! To avoid confusions put -- after options list or place file/directory name first in line. !!!
#
#   If you want to fix peak on the end of database, where peak span can be less then defined, use 'fix-end' option.
#   If you cannot understand why script doesn't find a peak while it's exactly present in defined time diapason,
#   you can use --analysis option. Maybe you may wide the peak span or reduce scale value.
#
#      OPTIONS: ---
# REQUIREMENTS: perl modules DateTime, Getopt::Long, rrdtool
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Alena Solodiankina (snus), alena.vladimirovna@gmail.com
#      COMPANY: TeNeT
#      VERSION: 1.0
#      CREATED: 12/24/12 14:54:02
#     REVISION: ---
#===============================================================================

use strict;
use warnings;
use DateTime;
use DateTime::Duration;
use Getopt::Long;
#use Data::Dumper;

use constant rrdInterval => 5; #in minutes
use constant rrdFileMark => qr/RRDTool DB/i;
use constant rrdtool => "rrdtool";
my $DEBUG;
my $STANDART_DIAPASON;

sub assert {
    my ($one,$two,$line) = @_;
    die "Failed assert at line $line\n" if ($one != $two);
}

sub checkDateFormat {
    my ($date) = @_;
    # CODE {{{1
    $date =~ s/^~//;
    my @strDate = ("today", "yesterday");
    return 1 if (grep {$_ eq $date} @strDate);
    
    return 0 unless ($date =~ /^\d{4}-\d{2}-\d{2}$/);
    my ($y,$m,$d) = split (/-/,$date);
    return 0 unless ($m >= 1 and $m < 12);
    return 0 unless ($d >= 1 and $d <= 31);
     # 1}}} 
    return 1;
}

#assert(checkDateFormat("yesterday"),1,__LINE__);
#assert(checkDateFormat("2013-40-12"),0,__LINE__);

sub checkTimeFormat {
    my ($time) = @_;
    # CODE{{{1
    return 0 unless ($time =~ /^\d{2}:\d{2}(:|$)/);
    my ($h,$m) = split(/:/, $time);
    return 0 unless ($h >= 0 and $h <= 23);
    return 0 unless ($m >= 0 and $m <= 59);
    # 1}}}
    return 1;
}

sub parseDate {
    my ($dateStr,$timeStr) = @_;
    # CODE {{{1  
    
    unless ($timeStr) {
        ($dateStr,$timeStr) = split(/\s+/, $dateStr);
    }
    
    my $dateObj;
    if ($dateStr eq 'today' or $dateStr eq 'yesterday') {
        $dateObj = DateTime->today();
        if ($dateStr eq 'yesterday') {
            $dateObj = $dateObj->subtract(days => 1);
        }
    } else {
        my ($year,$month,$date) = split(/-/,$dateStr);
        $dateObj = DateTime->new(year => $year, month => $month, day => $date);
    }

    if ($timeStr) {
        my ($h,$m) = split (/:/,$timeStr);
        $dateObj->set_hour($h); 
        $dateObj->set_minute($m);
    }
    print "DE: date is " . $dateObj->strftime("%Y-%m-%d"). "\n" if ($DEBUG);
    # 1}}}
    return ($dateObj);
}

sub getDateDiapason {
    my ($firstDate,$lastDate) = @_;
    # CODE {{{1           
    my @diapason;
    $firstDate = parseDate($firstDate);
    if ($lastDate) {
        $lastDate = parseDate($lastDate);
    } elsif ($STANDART_DIAPASON) {
        my $dateSpan = DateTime::Duration->new(days => 5);
        $lastDate = $firstDate + $dateSpan;
        $firstDate = $firstDate - $dateSpan;
    } else {
        $lastDate = $firstDate;
    }
    
    my $dateSpan = DateTime::Duration->new(days => 1);
    while ($firstDate != $lastDate) { 
        push (@diapason, $firstDate->strftime("%Y-%m-%d"));
        $firstDate += $dateSpan;
    }
    push (@diapason, $lastDate->strftime("%Y-%m-%d"));
    $, = " - ";
    print "DE: date diapason = @diapason\n" if ($DEBUG);
     # 1}}} 
    return (\@diapason);
}

sub getTimeDiapason {
    my ($date,$begin,$end) = @_;
    #  CODE{{{1
    my @diapason;
    $begin = parseDate($date,$begin);

    unless ($end) {
        my $timeSpan = DateTime::Duration->new(minutes => rrdInterval*3);
        $end = $begin + $timeSpan;
        $begin -= $timeSpan;
    } else {
        $end = parseDate($date,$end);
    }
    
    my $timeSpan = DateTime::Duration->new(minutes => rrdInterval);
    while ($begin != $end) {
        push(@diapason, $begin->strftime("%F %H:%M"));
        $begin += $timeSpan;
    }

    push(@diapason, $end->strftime("%F %H:%M"));
    
     # 1}}}
    return(\@diapason);
}

sub getSearchDiapason {
    my ($date,$time) = @_;

    if ($date =~ /^ARRAY/) {
        return (getDateDiapason(@$date));
    } else {
        if ($time->[0]) {
            return (getTimeDiapason($date,@$time));
        } else {
            return (getDateDiapason($date));
        }
    }
}
sub searchInDiapason {
    my ($line,$diapason) = @_;

    for my $pattern (@$diapason) {
        return 1 if ($line =~ /^\s*<!--\s*$pattern\b/);
    }
    return 0;
}

sub smoother {
    my ($fileContent,$searchDiapason,$scale,$peakSpan,$ANALYSIS,$fix_end) = @_;
    #CODE {{{1 
    my (@lastDs,%suspiciousData,$spanCount,$suspiciousMark,$rraType,@analysisInfo,$newRRAmark);

    my $timeInfo = sub {
        my @lines = sort {$a <=> $b} keys %suspiciousData;
        my $infoStr;

        if (@lines == 1) {
            $infoStr = $suspiciousData{$lines[0]}{time} 
        } else {
            $suspiciousData{$lines[0]}{time} =~ /^(\d+\S+\s\d+\S+)/;
            $infoStr = $1 . " - $suspiciousData{$lines[$#lines]}{time}";
        }
        $infoStr =~ s/\s\/.*$//;

        return ($infoStr);
    };

    my $analysisInfo = sub {
        my ($explanation) = @_;
        my $infoStr = $timeInfo->();
        $infoStr .= ": " . $explanation if ($explanation);

        if ($newRRAmark) { 
            push(@analysisInfo, $rraType);
            $newRRAmark = 0;
        }

        push(@analysisInfo, $infoStr);
    };

    for (my $i = 0; $i <= $#{$fileContent}; $i++) {
        my $_ = $fileContent->[$i];

        if (/<cf>(.*)<\/cf>/) {
            $rraType = "\nDatabase: $1 at ";
            $fileContent->[++$i] =~ /<!--\s+(\S.*)\s+-->/;
            $rraType .= $1;
            $newRRAmark = 1;

            next;
        }

        next unless (searchInDiapason($_,$searchDiapason));

        my ($time,@ds);

        /<!--\s+([^>]*)\s+-->/; $time = $1;
        @ds = /<v>\s*([^<\s]+)\s*<\/v>/g;

        my $zeroing = sub {
            $spanCount = $suspiciousMark = 0;
            %suspiciousData = ();
            @lastDs = @ds;
        };
    
        my $fix = sub {
           my @ds = @_;

           $analysisInfo->("fixed.");

           my $newStr = " <row>";
           for (my $j = 0; $j <= $#lastDs; $j++) {
               $newStr .= "<v> " . ($lastDs[$j] + $ds[$j])/2 . " </v>";
           }
           $newStr .= "</row>";

           for my $line (keys %suspiciousData) {
               $fileContent->[$line] = "<!-- $suspiciousData{$line}{time} -->" . $newStr;
           }
        };

        if ($suspiciousMark) {
            $spanCount++;

            for (my $j = 0; $j <= $#{$suspiciousData{$i-1}{ds}}; $j++) {
                my $thisScale;

                if ($ds[$j] != 0 and $ds[$j] ne 'NaN') {
                    $thisScale = $suspiciousData{$i-1}{ds}[$j]/$ds[$j];
                } else {
                    $thisScale = $suspiciousData{$i-1}{ds}[$j];
                }

                if ($thisScale >= $scale) {
                    $spanCount--;
                    $suspiciousMark = 0;

                    last;
                }
            }

            if ($suspiciousMark) {

                if ($peakSpan < $spanCount) {
                    if ($fileContent->[$i+1] =~ /<\/database>/) {
                        if ($ANALYSIS) {
                            $analysisInfo->("It can be a peak on the end of database, although peak span is $spanCount (<$peakSpan).");
                        } else {                            
                            $analysisInfo->("It can be a peak on the end of database, peak span is $spanCount (<$peakSpan). (If you want to fix it use 'fix-end' option.)");
                            if ($fix_end) {
                                $fix->(@ds);     
                            }
                        }
                    } else {
                        $analysisInfo->("seems like normal smooth change. Suspect \"peak\" takes minumum $spanCount measurements");
                    }
                    $zeroing->();
                } else {
                    print "\nDE: continue watching, it steal can be a peak\n" if ($DEBUG);
                    $suspiciousData{$i} = {ds => \@ds, time => $time};
                }
            } else {
                if ($peakSpan == $spanCount) {
                    if ($ANALYSIS) {
                        $analysisInfo->("I think it's a peak. It takes exactly $spanCount measurements.");
                        $zeroing->();
                        next;
                    }
                    $fix->(@ds);

                    $zeroing->();
                } else {
                    $analysisInfo->("I think it's not a peak. Posistive measurements count ($spanCount) isn't equal to defined peak span ($peakSpan)");

                    $zeroing->();
                }
            }
        } else {
            unless (@lastDs) { # we must check first value in file if it satisfies the time condition
                @lastDs = @ds;
                if (map { $_ ne 'NaN' or $_ > 0 } @ds) { # line with only null is not suspicious
                    $suspiciousData{$i}= {ds => \@ds, time => $time};                
                    $suspiciousMark = 1;
                    $spanCount = 1;
                }
                next;
            }
            for (my $j=0; $j <= $#ds; $j++) {
                my $thisScale;
                if ($lastDs[$j] !=0 and $lastDs[$j] ne 'NaN') {
                    $thisScale = $ds[$j]/$lastDs[$j];
                } else {
                    $thisScale = $ds[$j];
                }
                if ($thisScale >= $scale) {
                    $suspiciousData{$i}= {ds => \@ds, time => $time};

                    if ($fileContent->[$i+1] =~ /<\/database>/) {
#                        print $_ if ($DEBUG);
		                    if ($ANALYSIS) {
		                        $analysisInfo->("It can be a peak on the end of database, peak span is 1.");
		                    } else {
                                $analysisInfo->("It can be a peak on the end of database, peak span is 1 (<=$peakSpan) (if you want to fix it use 'fix-end' option).");
                                if ($fix_end) {
                                    $fix->(map {0} @ds);     
                                }
		                    }
                            $zeroing->();
                    } else {
#                    print "DE: $j: scale = $thisScale\n";
                        $suspiciousMark = 1;                        
                        $spanCount = 1;
                        last;
                    }
                }
            }
            unless ($suspiciousMark) {
                @lastDs = @ds;
            }
        }        
    }
    # 1}}} 
    return ($fileContent,\@analysisInfo);        
}

my $usage="Usage: $0 [-d date -t time -s scale -ts peak_span --debug --analysis --fix-end --] rrd_file/directory\nDate format yyyy-mm-dd, time format hh:mm\n";
my $help=<<END;
$usage
Script removes peaks on rrd graphs between specified time diapason. If some value on this diapason is significantly different (or in \"scale\" times different if scale's set) from previous and following values it's our peak and it'll be smoothered.
By default scale is 10 and more.
Peak span is a count of value measurements peak was present. Default is equal to 1.
Date can be exact and can be diapason. If it's diapason then time is ignored. You can specify a standart diapason (5 days before, 5 days after) by putting '~' before exact date.

Examples meaning the same date diapason:  
    -d 2013-11-01 2013-11-10
    -d ~2013-11-05
Example of exact date: 
    -d 2013-11-05

Time is always a diapason. If you specify a exact time without ~ it'll be standart diapason 15m before and after this time.

Examples: 
    -t 12:15
    -t 12:15 13:00        

To avoid confusions put -- after options list or place file/directory name first in line.

If you want to fix peak on the end of database, where peak span can be less then defined, use 'fix-end' option.

If you cannot understand why script doesn't find a peak while it's exactly present in defined time diapason, you can use --analysis option. Maybe you may wide the peak span.
END

die $usage unless @ARGV;

my (@dateDiapason,@time,$scale,$help_mark,$peakSpan,@files,$analysis,$fix_end);

GetOptions( "help|h|?" => sub { print $help; exit 0;},
            "d=s{1,2}" => \@dateDiapason, 
            "t=s{1,2}" => \@time,
            "ts=s" => \$peakSpan,
            "s=i" => \$scale,
            "analysis" => \$analysis,
            "fix-end|e" => \$fix_end,
            "debug" => \$DEBUG); 

die $usage unless (@ARGV);

$scale ||= 10;
$peakSpan ||= 1;


unless (@dateDiapason) {
    print "Date of the peak: ";
    chomp($dateDiapason[0] = <STDIN>);
    if ($dateDiapason[0] =~ /\s+/) {
        @dateDiapason = split (/\s+/,$dateDiapason[0]);
    }
}

for my $date (@dateDiapason) {
    die "Wrong date format \"$date\", abort.\n$usage" unless (checkDateFormat($date)); 
}

unless (@dateDiapason > 1) {
    unless (@time) {
        print "Approximate time of the peak: ";
        chomp($time[0] = <STDIN>);
    }
}
if ($time[0]) {
    for my $time (@time) {
        die "Wrong time format \"$time\", abort.\n$usage" unless (checkTimeFormat($time));
    }
}

for my $file (@ARGV) {
    if (-d $file) {
        opendir(D,$file) or warn "Cannot open $file: $!\n";
        while (my $inDir = readdir(D)) {
            next if ($inDir eq '.');
            next if ($inDir eq '..');

            push (@ARGV, "$file/$inDir");
        }
        close D;
    } else {
        if (`file $file` =~ rrdFileMark) {
            push (@files,$file);
        }
    }
}

my $searchDiapason;
if (@dateDiapason == 2) {
    $searchDiapason = getSearchDiapason(\@dateDiapason,\@time);
} else {
    if ($dateDiapason[0] =~ s/^~//) {
        $STANDART_DIAPASON = 1;
    }
    $searchDiapason = getSearchDiapason($dateDiapason[0],\@time);
}

FILE: for my $file (@files) {
    if ($analysis) {
        print "Analysis $file...\n";
    } else {
        print "Process $file...\n";
    }
    my $xmlFile = "$file.xml";
    my $bkpFile = ".$file.bkp";
    if (system("rrdtool dump $file > $xmlFile")) {
        warn "$file: cannot convert to xml. Skip it.\n";
    } else {
        unless (open(XML,"+< $xmlFile")) { 
            warn "Cannot open $xmlFile: $!. Skip it.\n";
            next;
        }
        chomp(my @xmlContent = <XML>);
        my ($newXmlContent,$analysisInfo) = smoother(\@xmlContent, $searchDiapason, $scale, $peakSpan, $analysis,$fix_end);    
        
        $,="\n";
        if ($analysis) {
            if (@$analysisInfo) { 
                print @$analysisInfo, "\n";
            } else {
                print ".. nothing looks like a peak.\n";
            }
            next;
        }
        unless (@$analysisInfo) {
            close XML;
            print "... nothing was changed.\n";
            next FILE;
        }

        seek(XML, 0, 0);
        print XML @$newXmlContent;
        truncate(XML, tell(XML));
        close XML;

        rename($file,"$bkpFile") or die "Cannot rename $file to $bkpFile: $!\n";
        if (system("rrdtool restore $xmlFile $file")) {
            warn "Cannot restore $file from $xmlFile: $!. Restoring old rrd file... ";
            rename($bkpFile,"$file") or die "\nCannot rename $bkpFile to $file: $!\n";
            warn "ok\n";
        }

        print @$analysisInfo,"\n";
    }
    print "\n";
}
