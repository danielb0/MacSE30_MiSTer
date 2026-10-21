#!/bin/sh
# pressure.sh - the same memory pressure every round before quitting a Mac
# application (SE30_PLAN.md KNOWN ISSUES 33: Mac environment apps bombing on
# exit, seen after X clients and a C compile).  Bourne shell and K&R C on
# purpose (A/UX 3.1).
#   sh pressure.sh [load|control] [megabytes]      default: load 10
# First open TextEditor (type a line or two) and leave it open.
#   load     xeyes, xclock and xcalc started, a C compile, then a program that
#            touches every 4 KB page of N megabytes twice (about two thirds of
#            the RAM pages the idle Mac application out); then you quit
#            TextEditor and answer the prompt; the X clients are stopped
#   control  none of that - you quit TextEditor at once
# Each round is one line in $HOME/pressure.log.
MODE=${1-load}
MB=${2-10}
LOG=$HOME/pressure.log
DIR=/tmp/pressure.$$
case $MODE in
load|control) ;;
*) echo "usage: sh pressure.sh [load|control] [megabytes]"; exit 1 ;;
esac
mkdir $DIR || exit 1
if [ "$MODE" = load ]; then
	if [ -z "$DISPLAY" ]; then
		echo "DISPLAY is not set - the X clients need it"; rm -rf $DIR; exit 1
	fi
	xeyes & P1=$!
	xclock & P2=$!
	xcalc & P3=$!
	sleep 5
	cat > $DIR/hog.c <<'EOF'
/* hog.c: touch every page of N megabytes twice, then exit */
#include <stdio.h>
extern char *malloc();
main(argc, argv)
int argc;
char **argv;
{
	long n, i;
	int mb, pass;
	char *p;

	mb = argc > 1 ? atoi(argv[1]) : 10;
	n = (long) mb * 1024L * 1024L;
	p = malloc((unsigned) n);
	if (p == 0) {
		fprintf(stderr, "hog: no memory for %d MB\n", mb);
		exit(1);
	}
	for (pass = 0; pass < 2; pass++)
		for (i = 0; i < n; i += 4096)
			p[i] = (char) (pass + (i >> 12));
	printf("hog: %d MB touched twice\n", mb);
	exit(0);
}
EOF
	cc -O -o $DIR/hog $DIR/hog.c || { kill $P1 $P2 $P3; rm -rf $DIR; exit 1; }
	$DIR/hog $MB
fi
echo "Now quit TextEditor.  Did it bomb? (y/n)"
read ANS
echo "`date` $MODE $MB MB: $ANS" >> $LOG
if [ "$MODE" = load ]; then
	kill $P1 $P2 $P3
fi
rm -rf $DIR
echo "logged to $LOG:"
tail -3 $LOG
