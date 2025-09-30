#---------------------------------------------
# r_Serial.pm
#---------------------------------------------

package r_serial;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use Win32::Console;
use r_utils;
use base 'Wx::App';


my $dbg_serial = 0;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

        startSerialThread

    );
}

my $console_in;
my $buffer:shared = '';



sub startSerialThread
{
    display(0,0,"startSerialThread()");
    $console_in = Win32::Console->new(STD_INPUT_HANDLE);
    $console_in->Mode(ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT ) if $console_in;
    return error("could not open Win32::Console") if !$console_in;
    display(0,1,"Win32::Console opened");
    my $serial_thread = threads->create(\&serialThread);
    $serial_thread->detach();
    display(0,0,"startSerialThread() finished");

}



sub isEventCtrlC
    # my ($type,$key_down,$repeat_count,$key_code,$scan_code,$char,$key_state) = @event;
    # my ($$type,posx,$posy,$button,$key_state,$event_flags) = @event;
{
    my (@event) = @_;
    if ($event[0] &&
        $event[0] == 1 &&      # key event
        $event[5] == 3)        # char = 0x03
    {
        warning(0,0,"ctrl-C pressed ...");
        return 1;
    }
    return 0;
}


sub getChar
{
    my (@event) = @_;
    if ($event[0] &&
        $event[0] == 1 &&       # key event
        $event[1] == 1 &&       # key down
        $event[5])              # char
    {
        return chr($event[5]);
    }
    return undef;
}


sub handleCommandLine
{
    my $lpart = $buffer;
    my $rpart = '';
    ($lpart,$rpart) = ($1,$2) if $buffer =~ /^(.*?) (.*)$/;
    $lpart = lc($lpart);
    $lpart =~ s/^\s+|\s+$//g;
    $rpart =~ s/^\s+|\s+$//g;
    shark::handleCommand($lpart,$rpart);
    $buffer = '';
}


sub serialThread
{
    display(0,0,"serialThread() started");
    while (1)
    {
        if ($console_in->GetEvents())
        {
            my @event = $console_in->Input();
            if (@event && isEventCtrlC(@event))			# CTRL-C
            {
                warning(0,0,"EXITING PROGRAM from serial_thread()");
                kill 6,$$;
            }
            my $char = getChar(@event);
            if (defined($char))
            {
                # control characters

                if (ord($char) == 4)            # CTRL-D
                {
                    $CONSOLE->Cls();    # manually clear the screen
                    next;
                }

                # printf "got(0x%02x)='%s'\n",ord($char),$char ge " "?$char:'';
                $CONSOLE->Write($char);
                if (ord($char) == 0x0d)
                {
                    $CONSOLE->Write("\n");
                    $buffer =~ s/^\s+|\s$//g;
                    handleCommandLine() if length($buffer);
                }
                else
                {
                    $buffer .= $char;
                }
            }
        }
        else
        {
            sleep(0.1);
        }

    }   # while (1)
}   #   serialThread()



1;