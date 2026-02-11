pong game, v1.1 written by Hrvoje Cavrak, 12/2018
/ Modified for 1024x768 resolution by Jelena Kovacevic, REGOC team, 02/2026
/ Changes:
/   - maxdown: 0o764 (500) -> 0o600 (384) for 768 vertical
/   - ymask: 0o777 (511) -> 0o577 (383) for random Y in range
/   - limitup: 0o562 (370) -> 0o420 (272) so paddle+width stays visible
/   - limitdown: 0o760 (496) -> 0o540 (352) so paddle stays visible at bottom
/   - pdlwidth: 0o150 (104) -> 0o140 (96) smaller paddle for 768 height
/   - pdlhalf: 0o64 (52) -> 0o60 (48) half of new pdlwidth
/   - maxright: unchanged (0o764 = 500, close enough to 512)

	ioh=iot i
	szm=sza sma-szf

define swap
	rcl 9s
	rcl 9s
	terminate

define  point A, B
	law B
	add y
	sal 8s

	swap

	law A
	add x
	sal 8s

	dpy-i 300
	ioh
	terminate



/ 5 points
define  circle A, B
	point 0, 1
	point 0, 3

	point 4, 1
	point 4, 3

	point 1, 0
	point 1, 3

	point 1, 4
	point 3, 4

	terminate

define paddle X, Y				/ Draws paddles
	lac pdlwidth
	cma
	dac p1cnt
pdloop,
	lac Y
	add pdlwidth
	add p1cnt
	sal 8s

	swap

	lac X
	dpy-i 300
	ioh

	law 0					/ Changed from 6 to 0 for 1-pixel step (0+1=1)
	add p1cnt
	dac p1cnt
	isp p1cnt

	jmp pdloop+R
	terminate

define line C, D				/ Central line which acts as the "net"
 	law 0
	sub maxdown
	sub maxdown
	dac p1cnt

ploop2,
	lac p1cnt
	add maxdown
	sal 9s

	swap
	law D
	dpy
	ioh

	law 70
	add p1cnt
	dac p1cnt

	isp p1cnt
	jmp ploop2+R
	terminate



0/	opr
	opr
	opr
	opr
	jmp loop


500/
loop,   circle
	lac x
	add dx
	dac x

	jsp checkx

	lac y
	add dy
	dac y

	jsp checky

	paddle left, pdl1y
	paddle right, pdl2y

	jsp move

	line 0, 0

	jmp loop


define testkey K, N				/ Tests if key K was pressed and skips to N if it is not
	lac controls
	and K
	sza
	jmp N
	terminate

define padmove Y, A				/ Initiates moving of the pads
	lac Y
	dac pdly
	jsp A
	lac pdly
	dac Y
	terminate


move,
	dap mvret				/ Moves the paddles
	cli					/ Load current controller button state
	iot 11
	dio controls

move1,
	testkey rghtup, move2			/ Right UP
	padmove pdl1y, mvup

move2,
	testkey leftup, move3			/ Left UP
	padmove pdl2y, mvup

move3,						/ Right DOWN
	testkey rghtdown, move4
	padmove pdl1y, mvdown

move4,						/ Left DOWN
	testkey leftdown, mvret
	padmove pdl2y, mvdown

mvret,  jmp .


define flip A
	lac A
	cma
	dac A
	terminate


mvup,	dap upret				/ Move pad UP
	lac pdly
	sub limitup				/ Check if pad at top edge
	sma
	jmp upret				/ Do nothing if it is
	lac pdly
	add padoff
	dac pdly

	add random				/ Use pad coordinates as user provided randomness
	dac random

upret, jmp .

mvdown,	dap downret
	lac pdly
	add limitdown
	spa
	jmp downret
	lac pdly
	sub padoff
	dac pdly

	add random				/ Use pad coordinates as user provided randomness
	dac random
downret, jmp .



delay, dap dlyret
	lac dlytime
	dac dlycnt
dlyloop,
	isp dlycnt
	jmp dlyloop

dlyret, jmp .


restart,
	jsp delay
	idx iter				/ Count the number of restarts

	lac random
	and dymask
	add one					/ Don't want it to be 0
	dac dy

	cla
	dac x

	lac random
	and ymask
	sub maxdown
	dac y

	lac iter
	and one
	sza
	jmp rr

rl,
	law 7				/ Changed from 2 to 7 for faster ball
	cma
	dac dx

	add offscrn
	dac x

	jmp ckret
rr,
	law 7				/ Changed from 2 to 7 for faster ball
	dac dx

	sub offscrn
	dac x

	jmp ckret



hitpaddle, dap ckret				/ Check for colision with paddle
	lac y
	sub pdly
	sub one
	spa					/ must be true: y - pdl1y > 0
	jmp restart				/ return if not

	sub pdlwidth
	sma					/ must be true: y - pdlwidth - pdl1y < 0
	jmp restart				/ return if not

	flip dx
	idx dirchng				/ Count number of paddle hits, increase speed subsequently

	lac dx
	spa
	jmp skipfast				/ Consider increasing dx only if positive

	law 3					/ if 3 - dirchng < 0 (every 3 hits from right paddle), increase speed
	sub dirchng
	spa
	idx dx
	spa
	dzm dirchng				/ Reset dirchng counter back to zero, everything starts from scratch
skipfast,

	lac pdly				/ get distance from center of paddle
	add pdlhalf
	sub y

	spa
	cma					/ take abs() of accumulator
	sar 4s					/ shift 3 bits right (divide by 8)
	add one					/ To prevent x-only movement, add 1 so it should never be zero

	/ Here, accumulator holds the absolute offset from the paddle center divided by 8

	lio dy					/ Load dy to IO not to destroy ACC contents
	spi					/ If dy is positive, subtract
	cma

	dac dy					/ Set new y bounce angle

ckret,  jmp .


checkx,
	dap cxret
	lac pdl1y				/ Load position of right paddle
	dac pdly
	lac x
	add maxright				/ AC = x + maxright, if x < -500, swap dx
	spa
	jsp hitpaddle

	lac pdl2y				/ Load position of left paddle
	dac pdly
	lac x
	sub maxright				/ AC = x - maxright, if x > 500, swap dx
	sma
	jsp hitpaddle
cxret, jmp .


checky,
	dap cyret
	lac y
	add maxdown				/ AC = y + maxdown, if y < -384, swap dy
	spa
	jmp cnext
	flip dy

cnext,
	lac y
	sub maxdown				/ AC = y - maxdown, if y > 384, swap dy
	sma
	jmp cyret
	flip dy
cyret, jmp .


////////////////////////////////////////////////////////////////////////////////////////////////

x,		000500
y,		000000

dx,		777771		/ Changed from 777775 (-3) to 777771 (-7) for faster ball
dy,		000007		/ Changed from 000003 (3) to 000007 (7) for faster ball

iter,		000000

padoff, 	000014
random,		000001

pdly,		000000

pdl1y, 		000000
pdl2y, 		000000

p1cnt,	  	000000
controls, 	000000

left, 		400400
right, 		374000

pdlwidth, 	000140
pdlhalf,  	000060

one,		000001

maxright,  	000764
maxdown,   	000600

offscrn,	000500
dymask,		000007		/ Changed from 000003 (0-3) to 000007 (0-7) for more dy variation
ymask,		000577

limitup,	000420
limitdown,	000540

leftdown,   	000001
leftup,		000002

rghtdown,	040000
rghtup,	 	100000

dlytime,	770000
dlycnt,		000000
dirchng,	000000				/ Counts direction changes, used for increasing ball speed

	start 500
