# The demo is source code, not a recording.
#
# Regenerate with:  ./demo/setup.sh && vhs demo.tape
#
# Nothing here is staged: the command shown is the command that runs, against the fixture
# built by demo/setup.sh. The prompt is reset before recording so the GIF carries no
# username or hostname, which is the same class of mistake this tool exists to catch.

Output docs/demo.gif

Set Shell bash
Set FontSize 15
Set Width 1180
Set Height 640
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 55ms

Hide
Type "export PS1='$ ' PATH=$PWD/bin:$PATH PUBLISHABLE_CONFIG_FILE=/tmp/publishable-demo/config"
Enter
Type "cd /tmp/publishable-demo && clear"
Enter
Show

Sleep 700ms
Type "publishable check my-app"
Sleep 400ms
Enter
Sleep 6s
