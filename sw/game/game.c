#include "keyhelp.h"
#include "audio.h"
#include "fat16.h"
#include "minilib.h"
#include "accel.h"
#include "malloc.h"
#include "multibuf.h"

#define MAX_QBEATS 50000
#define SCREEN_WIDTH 640
#define SCREEN_HEIGHT 480

/* SCORES (higher number = worse result)*/
#define MARVELOUS 1
#define PERFECT 2
#define GREAT 3
#define GOOD 4
#define BOO 5
#define MISS 6
#define NONE 0

int marvelouses;
int perfects;
int greats;
int goods;
int boos;
int misses;


#define AUDIO_SAMPLE_RATE 48000

/* Bit offset of each arrows in the qstep byte */
#define LEFT_POS 3
#define DOWN_POS 2
#define UP_POS 1
#define RIGHT_POS 0

#define LEFT_KEY 'j'
#define DOWN_KEY 'k'
#define UP_KEY 'i'
#define RIGHT_KEY 'l' 

/* Sample Offset */
#define SAMPLE_OFFSET_MARVELOUS ((int)(AUDIO_SAMPLE_RATE*0.0225))
#define SAMPLE_OFFSET_PERFECT ((int)(AUDIO_SAMPLE_RATE*0.045))
#define SAMPLE_OFFSET_GREAT ((int)(AUDIO_SAMPLE_RATE*0.09))
#define SAMPLE_OFFSET_GOOD ((int)(AUDIO_SAMPLE_RATE*0.135))
#define SAMPLE_OFFSET_BOO ((int)(AUDIO_SAMPLE_RATE*0.18))

/* Some magical offset values that seem to improve video synchronization */
#define SAMPLE_TO_VIDEO_OFFSET 5600

#define MAX(x,y) ((x) > (y)) ? (x) : (y)

static unsigned char chars[] = {
#include "chars.inc"
};

int offset;

struct menusong {
	char name[32];
	char artist[31];
	char prefix[9];
};

struct stepfile {
	unsigned int len_qbeats;
	signed int samps_per_qbeat;
	signed int delay_samps;
	unsigned char qsteps[MAX_QBEATS];
};


int load_steps(struct fat16_handle * h, struct stepfile * song, char * filename)
{
	int rv;
	struct fat16_file fd;
	
	printf("Opening %s...", filename);
	if (fat16_open_by_name(h, &fd, filename) == -1)
	{
		printf("not found?\r\n");
		return -1;
	} 
	
	rv = fat16_read(&fd, song, 3*sizeof(int));
	if (rv < 0) {
		printf("error reading initial song data (%d)\r\n", rv);
		return -1;
	}

	printf("%u %x, %u %x; length read %u %x\r\n", song->len_qbeats, song->len_qbeats, song->samps_per_qbeat, song->samps_per_qbeat, rv, rv);
	
	if (song->len_qbeats > MAX_QBEATS) {
		printf("song too long (%x qbeats)\r\n", song->len_qbeats);
		return -1;
	}
	
	rv = fat16_read(&fd, (void*)(&song->qsteps), song->len_qbeats*sizeof(char));
	if (rv < 0) {
		printf("error reading initial step data (%d)\r\n", rv);
		return -1;
	}

	printf("loaded! (%d bytes)\r\n", rv);
	return 0;
}


struct img_resource
{
	unsigned int w;
	unsigned int h;
	unsigned int pixels[];
};

#define SPRITE_DIM 64
#define OTHER_ENDIANNESS(x) (((x>>24) & 0xff) | ((x >> 8) & 0xff00) | ((x << 8) & 0xff0000) | ((x << 24) & 0xff000000))
#define DRAW_PIX(buf, img, x0, y0, y, x) if ((img)[SPRITE_DIM*(y)+(x)]&0xff000000) (buf)[SCREEN_WIDTH*(y0+y)+(x0+x)] = OTHER_ENDIANNESS((img)[SPRITE_DIM*(y)+(x)]);

struct img_resource *img_load(struct fat16_handle *h, char *name)
{
	int rv;
	struct fat16_file fd;
	struct img_resource *r;
	
	printf("Loading image resource %s... ", name);
	if (fat16_open_by_name(h, &fd, name) == -1)
	{
		printf("not found?\r\n");
		return NULL;
	} 
	
	r = malloc(fd.len);
	if (!r)
	{
		printf("out of memory?\r\n");
		return NULL;
	}
	
	rv = fat16_read(&fd, (void *)r, fd.len);
	if (rv != fd.len) {
		printf("short read (%d)\r\n", rv);
		free(r);
		return NULL;
	}

	printf("%dx%d image\r\n", r->w, r->h);
	
	return r;
}

void bitblt(unsigned int *fb, unsigned int x0, unsigned int y0, struct img_resource *r) {
	int x, y;
	unsigned int *buf;
	
	if (((x0 + r->w) > 640) || ((y0 + r->h) > 480))
	{
		/*printf("BOUNDS CHECK!\r\n");*/
		return;
	}
	
	buf = r->pixels;
	for (y = 0; y < r->h; y++) {
		for (x = 0; x < r->w; x+=8) {
			if (*buf & 0x000000FF)
				fb[SCREEN_WIDTH*(y0+y)+(x0+x+0)] = *buf;
			buf++;
			
			if (*buf & 0x000000FF)
				fb[SCREEN_WIDTH*(y0+y)+(x0+x+1)] = *buf;
			buf++;
			
			if (*buf & 0x000000FF)
				fb[SCREEN_WIDTH*(y0+y)+(x0+x+2)] = *buf;
			buf++;
			
			if (*buf & 0x000000FF)
				fb[SCREEN_WIDTH*(y0+y)+(x0+x+3)] = *buf;
			buf++;
			
			if (*buf & 0x000000FF)
				fb[SCREEN_WIDTH*(y0+y)+(x0+x+4)] = *buf;
			buf++;
			
			if (*buf & 0x000000FF)
				fb[SCREEN_WIDTH*(y0+y)+(x0+x+5)] = *buf;
			buf++;
			
			if (*buf & 0x000000FF)
				fb[SCREEN_WIDTH*(y0+y)+(x0+x+6)] = *buf;
			buf++;
			
			if (*buf & 0x000000FF)
				fb[SCREEN_WIDTH*(y0+y)+(x0+x+7)] = *buf;
			buf++;
		}
	}
}

void cons_drawchar_with_scale_3(unsigned int *buf, int c, int x, int y, int fg, int bg)
{
	int xx, yy;
	int i, j;
	buf = buf + (y*SCREEN_WIDTH+x);
	
	for (yy = 0; yy < 8; yy++) 
		for (xx = 0; xx < 8; xx++) 
			for (i = 0; i < 3; i++)
				for (j = 0; j < 3; j++)
					buf[(yy*3+j) * SCREEN_WIDTH + (7 - (xx*3+i))] = ((chars[c*8 + yy] >> xx) & 1) ? fg : bg;
}

struct img_resource *left_arrows[4];
struct img_resource *down_arrows[4];
struct img_resource *up_arrows[4];
struct img_resource *right_arrows[4];

multibuf_t *bufs;

void splat_text(unsigned int *buf, char* string, int x, int y, int fg, int bg)
{
	while (*string != '\0') {
		cons_drawchar_with_scale_3(buf, (int)(*string), x, y, fg, bg);
		string++;
		x+= 24;
	}
}

void splat_loading()
{
	int i;
	static unsigned int *buf = NULL;
	static int c = 0;
	
	if (!buf)
	{
		buf = multibuf_flip(bufs);
	}
	
	printf(".");
	
//	for (i = 0; i < 4; i++)
//	{
//		bitblt(buf,  25, 50+50*i, left_arrows[i]);
//		bitblt(buf, 100, 50+50*i, down_arrows[i]);
//		bitblt(buf, 175, 50+50*i, up_arrows[i]);
//		bitblt(buf, 250, 50+50*i, right_arrows[i]);
//	}

	cons_drawchar_with_scale_3(buf, (int)'L', 200+24*0, 300, gencol(c+10), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'o', 200+24*1, 300, gencol(c+20), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'a', 200+24*2, 300, gencol(c+30), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'d', 200+24*3, 300, gencol(c+40), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'i', 200+24*4, 300, gencol(c+50), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'n', 200+24*5, 300, gencol(c+60), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'g', 200+24*6, 300, gencol(c+70), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'.', 200+24*7, 300, gencol(c+80), 0x000000);
	c += 10;

	buf = multibuf_flip(bufs);

}

unsigned int *load_audio(struct fat16_handle *h, int *length, char *filename)
{
	int rv;
	int len, tlen;
	struct fat16_file fd;
	unsigned int *p;
	
	printf("Opening %s... ", filename);
	if (fat16_open_by_name(h, &fd, filename) == -1)
	{
		printf("not found?\r\n");
		return NULL;
	} 
	
	p = malloc(fd.len + 64);
	if (!p)
	{
		printf("malloc(%d) failed!\n", fd.len + 64);
		return NULL;
	}
	
	p = (unsigned int *)(((unsigned int)p + 64) & ~63);
	
	len = fd.len;
	tlen = 0;
	while (len)
	{
		int thislen = (len > 16384) ? 16384 : len;
		rv = fat16_read(&fd, ((void*)p) + tlen, thislen);
		if (rv != thislen)
		{
			printf("short read?\r\n");
			return NULL;
		}
		splat_loading();
		tlen += rv;
		len -= rv;
	}
	printf("loaded! (%d bytes)\r\n", tlen);
	
	if (length)
		*length = tlen;
	
	return p;
}


static struct stepfile song;

/* left up down right for the game */
int l, u, d, r;

int check_hit_dir(int dir, int pressed){
	/* get rid of the bits that were already hit such that all the bits that are left
           are now misses */
	int i;
        int qbeat_offset = 0;
	int samples_played = audio_samples_played();
        signed int qbeats = samples_played-song.delay_samps-1600+song.samps_per_qbeat/2;
	signed int qbeat_round = qbeats/song.samps_per_qbeat;
	if (pressed) {
		i = 0;
                qbeat_offset = (qbeats+SAMPLE_OFFSET_MARVELOUS)/song.samps_per_qbeat-qbeat_round;
		for (; i <= qbeat_offset; i++) {
			if ((qbeat_round-i >= 0) && (song.qsteps[qbeat_round-i] >> dir) & 1) {
				song.qsteps[qbeat_round-i] &= ~(1 << dir);
				marvelouses++;
				return MARVELOUS;
			}
			else if ((qbeat_round+i < song.len_qbeats) && 
				 (song.qsteps[qbeat_round+i] >> dir) & 1) {
				song.qsteps[qbeat_round+i] &= ~(1 << dir);
				marvelouses++;
				return MARVELOUS;
			}
		}
                i = qbeat_offset+1;
		qbeat_offset = (qbeats+SAMPLE_OFFSET_PERFECT)/song.samps_per_qbeat-qbeat_round;
		for (; i <= qbeat_offset; i++) {
			if ((qbeat_round-i >= 0) && (song.qsteps[qbeat_round-i] >> dir) & 1) {
				song.qsteps[qbeat_round-i] &= ~(1 << dir);
				perfects++;
				return PERFECT;
			}
			else if ((qbeat_round+i < song.len_qbeats) && 
				 (song.qsteps[qbeat_round+i] >> dir) & 1) {
				song.qsteps[qbeat_round+i] &= ~(1 << dir);
				perfects++;
				return PERFECT;
			}
		}
                i = qbeat_offset+1;
		qbeat_offset = (qbeats+SAMPLE_OFFSET_GREAT)/song.samps_per_qbeat-qbeat_round;
		for (; i <= qbeat_offset; i++) {
			if ((qbeat_round-i >= 0) && (song.qsteps[qbeat_round-i] >> dir) & 1) {
				song.qsteps[qbeat_round-i] &= ~(1 << dir);
				greats++;
				return GREAT;
			}
			else if ((qbeat_round+i < song.len_qbeats) && 
				 (song.qsteps[qbeat_round+i] >> dir) & 1) {
				song.qsteps[qbeat_round+i] &= ~(1 << dir);
				greats++;
				return GREAT;
			}
		}
                i = qbeat_offset+1;
		qbeat_offset = (qbeats+SAMPLE_OFFSET_GOOD)/song.samps_per_qbeat-qbeat_round;
		for (; i <= qbeat_offset; i++) {
			if ((qbeat_round-i >= 0) && (song.qsteps[qbeat_round-i] >> dir) & 1) {
				song.qsteps[qbeat_round-i] &= ~(1 << dir);
				goods++;
				return GOOD;
			}
			else if ((qbeat_round+i < song.len_qbeats) && 
				 (song.qsteps[qbeat_round+i] >> dir) & 1) {
				song.qsteps[qbeat_round+i] &= ~(1 << dir);
				goods++;
				return GOOD;
			}
		}
                i = qbeat_offset+1;
		qbeat_offset = (qbeats+SAMPLE_OFFSET_BOO)/song.samps_per_qbeat-qbeat_round;
		for (; i <= qbeat_offset; i++) {
			if ((qbeat_round-i >= 0) && (song.qsteps[qbeat_round-i] >> dir) & 1) {
				song.qsteps[qbeat_round-i] &= ~(1 << dir);
				boos++;
				return BOO;
			}
			else if ((qbeat_round+i < song.len_qbeats) && 
				 (song.qsteps[qbeat_round+i] >> dir) & 1) {
				song.qsteps[qbeat_round+i] &= ~(1 << dir);
				boos++;
				return BOO;
			}
		}
	}
	int boo_qbeat_offset = (qbeats+SAMPLE_OFFSET_BOO)/song.samps_per_qbeat-qbeat_round;
	if ((qbeat_round-(boo_qbeat_offset+1) >= 0) && 
	    (song.qsteps[qbeat_round-(boo_qbeat_offset+1)] >> dir) & 1) {
		song.qsteps[qbeat_round-(boo_qbeat_offset+1)] &= ~(1 << dir);
		misses++;
		return MISS;
	}
	return NONE;

}

int check_hit(){
	volatile unsigned int* scancodeaddr = 0x85000000;
	unsigned int scancode;
	int lnow = l;
	int unow = u;
	int dnow = d;
	int rnow = r;
	kh_type k;
	char new_char;
	int hit = NONE;
	

	int i;

	int hit_l = NONE;
	int hit_u = NONE;
	int hit_d = NONE;
	int hit_r = NONE;

	while ((scancode = *scancodeaddr) != 0xffffffff) {
		k = process_scancode(scancode);
		if (KH_HAS_CHAR(k)) {
			new_char = KH_GET_CHAR(k);
			switch (new_char) {
				case LEFT_KEY: lnow = !KH_IS_RELEASING(k); break;
				case DOWN_KEY: dnow = !KH_IS_RELEASING(k); break;
				case UP_KEY: unow = !KH_IS_RELEASING(k); break;
				case RIGHT_KEY: rnow = !KH_IS_RELEASING(k); break;
				case '7': 
					if (!KH_IS_RELEASING(k)) {
						offset -= 1000; 
						printf("Offset: %d\r\n", offset);
					}
					break;
				case '8': 
					if (!KH_IS_RELEASING(k)) {
						offset -= 100; 
						printf("Offset: %d\r\n", offset);
					}
					break;
				case '9': 
					if (!KH_IS_RELEASING(k)) {
						offset += 100; 
						printf("Offset: %d\r\n", offset);
					}
					break;
				case '0':
					if (!KH_IS_RELEASING(k)) {
						offset += 1000; 
						printf("Offset: %d\r\n", offset);
					}
					break;
			}
		}
	}

	hit_l = check_hit_dir(LEFT_POS, lnow && !l);
	hit_d = check_hit_dir(DOWN_POS, dnow && !d);
	hit_u = check_hit_dir(UP_POS, unow && !u);
	hit_r = check_hit_dir(RIGHT_POS, rnow && !r);
	
	l = lnow;
	u = unow;
	d = dnow;
	r = rnow;
	return MAX(MAX(MAX(hit_l, hit_d), hit_u), hit_r);

}

void game(struct fat16_handle * h, char * prefix)
{
	marvelouses = 0;
	perfects = 0;
	greats = 0;
	goods = 0;
	boos = 0;
	misses = 0;
	int i, j;
	int length;
	int rv;
	volatile int* cycles = 0x86000000;
	char fname[12];

	unsigned int *audio_mem_base;
	
	left_arrows[0] = img_load(h, "LEFT_4  RES");
	left_arrows[1] = img_load(h, "LEFT_16 RES");
	left_arrows[2] = img_load(h, "LEFT_8  RES");
	left_arrows[3] = left_arrows[1];
	
	right_arrows[0] = img_load(h, "RIGHT_4 RES");
	right_arrows[1] = img_load(h, "RIGHT_16RES");
	right_arrows[2] = img_load(h, "RIGHT_8 RES");
	right_arrows[3] = right_arrows[1];
	
	up_arrows[0] = img_load(h, "UP_4    RES");
	up_arrows[1] = img_load(h, "UP_16   RES");
	up_arrows[2] = img_load(h, "UP_8    RES");
	up_arrows[3] = up_arrows[1];
	
	down_arrows[0] = img_load(h, "DOWN_4  RES");
	down_arrows[1] = img_load(h, "DOWN_16 RES");
	down_arrows[2] = img_load(h, "DOWN_8  RES");
	down_arrows[3] = down_arrows[1];
	
	struct img_resource *left_spot = img_load(h, "LEFTSPOTRES");
	struct img_resource *right_spot = img_load(h, "RIGHSPOTRES");
	struct img_resource *up_spot = img_load(h, "UP_SPOT RES");
	struct img_resource *down_spot = img_load(h, "DOWNSPOTRES");
	
	/* Load music. */
	
	splat_loading();

	memcpy(fname, prefix, 8);
	memcpy(fname+8, "FM ", 4);

	rv = load_steps(h, &song, fname);
	if (rv < 0) {
		printf("Failure loading steps! (%d)\r\n", rv);
		return;
	}

	memcpy(fname+8, "RAW", 4);

	audio_mem_base = load_audio(h, &length, fname);
	if (!audio_mem_base) {
		printf("Failure loading audio! (%d)\r\n", rv);
		return;
	}


	printf("qbeats: %d; samps_per_qbeat: %d; playing...\r\n", song.len_qbeats, song.samps_per_qbeat);

	audio_play(audio_mem_base, length, AUDIO_MODE_ONCE);

	volatile unsigned int * scancodeaddr = 0x85000000;
	unsigned int scancode;
	volatile unsigned int* cycleaddr = 0x86000000;
	kh_type k;
	char new_char;

	unsigned int * buf;

	l = 0;
	u = 0;
	d = 0;
	r = 0;

	int hit = NONE;
	int last_hit = NONE;
	int prev_cycle = *cycleaddr;
	int curr_cycle = *cycleaddr;
	buf = multibuf_flip(bufs);
	offset = SAMPLE_TO_VIDEO_OFFSET;

	while (!is_audio_done(length)) {
		signed int qbeat, rem, qbeat_round;
		char datum;
		int i;
		int lnow = l;
		int unow = u;
		int dnow = d;
		int rnow = r;
		int samples_played;
		
		curr_cycle = *cycleaddr;
		/*printf("Cycles: %d\r\n", curr_cycle-prev_cycle);*/
		prev_cycle = curr_cycle;

		if (qbeat < 0)
			continue;

		if (hit == NONE)	
			hit = check_hit(qbeat_round, rem);

		accel_fill(buf, 0x00000000, SCREEN_WIDTH*SCREEN_HEIGHT);

		bitblt(buf,  25, 50, left_spot);
		bitblt(buf, 100, 50, down_spot);
		if (hit == NONE)
			hit = check_hit();
		bitblt(buf, 175, 50, up_spot);
		bitblt(buf, 250, 50, right_spot);
		if (hit == NONE)
			hit = check_hit();

		samples_played = audio_samples_played()+offset;
		qbeat = (samples_played-song.delay_samps-1600)/song.samps_per_qbeat;
		rem = (samples_played-song.delay_samps-1600)%song.samps_per_qbeat;
		qbeat_round = (samples_played-song.delay_samps-1600+song.samps_per_qbeat/2)/song.samps_per_qbeat;

		for (i = 7; i >= -1; i--) {
			int y = 50 + 50 * i + 50 * (song.samps_per_qbeat - rem) / song.samps_per_qbeat;
			int spot_in_beat = (qbeat + i) % 4;
			datum = song.qsteps[qbeat+i];
			if ((datum >> 3) & 1)
				bitblt(buf, 25, y, left_arrows[spot_in_beat]);
			if ((datum >> 2) & 1)
				bitblt(buf, 100, y, down_arrows[spot_in_beat]);
			if (hit == NONE)
				hit = check_hit();
			if ((datum >> 1) & 1)
				bitblt(buf, 175, y, up_arrows[spot_in_beat]);
			if ((datum >> 0) & 1)
				bitblt(buf, 250, y, right_arrows[spot_in_beat]);
			if (hit == NONE)
				hit = check_hit();
		}
		if (hit == NONE)
			hit = last_hit;
		else
			last_hit = hit;
		switch (hit) {
			case MARVELOUS:
				cons_drawchar_with_scale_3(buf, (int)'M', 100, 200, 0xffffffff, 0x00000000);
				cons_drawchar_with_scale_3(buf, (int)'A', 100+24*1, 200, 0xffffffff, 0x00000000);	
				hit = check_hit();
				cons_drawchar_with_scale_3(buf, (int)'R', 100+24*2, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'V', 100+24*3, 200, 0xffffffff, 0x00000000);		
				if (hit == NONE)	
					hit = check_hit();
				cons_drawchar_with_scale_3(buf, (int)'E', 100+24*4, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'L', 100+24*5, 200, 0xffffffff, 0x00000000);			
				if (hit == NONE)	
					hit = check_hit();
				cons_drawchar_with_scale_3(buf, (int)'O', 100+24*6, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'U', 100+24*7, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'S', 100+24*8, 200, 0xffffffff, 0x00000000);			
				break;
			case PERFECT:	
				cons_drawchar_with_scale_3(buf, (int)'P', 100, 200, 0xffffffff, 0x00000000);
				cons_drawchar_with_scale_3(buf, (int)'E', 100+24*1, 200, 0xffffffff, 0x00000000);	
				hit = check_hit();
				cons_drawchar_with_scale_3(buf, (int)'R', 100+24*2, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'F', 100+24*3, 200, 0xffffffff, 0x00000000);		
				if (hit == NONE)	
					hit = check_hit();
				cons_drawchar_with_scale_3(buf, (int)'E', 100+24*4, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'C', 100+24*5, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'T', 100+24*6, 200, 0xffffffff, 0x00000000);			
				break;
			case GREAT:
				cons_drawchar_with_scale_3(buf, (int)'G', 100, 200, 0xffffffff, 0x00000000);
				cons_drawchar_with_scale_3(buf, (int)'R', 100+24*1, 200, 0xffffffff, 0x00000000);	
				hit = check_hit();
				cons_drawchar_with_scale_3(buf, (int)'E', 100+24*2, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'A', 100+24*3, 200, 0xffffffff, 0x00000000);
				cons_drawchar_with_scale_3(buf, (int)'T', 100+24*4, 200, 0xffffffff, 0x00000000);
				break;
			case GOOD:
				cons_drawchar_with_scale_3(buf, (int)'G', 100, 200, 0xffffffff, 0x00000000);
				cons_drawchar_with_scale_3(buf, (int)'O', 100+24*1, 200, 0xffffffff, 0x00000000);	
				hit = check_hit();
				cons_drawchar_with_scale_3(buf, (int)'O', 100+24*2, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'D', 100+24*3, 200, 0xffffffff, 0x00000000);
				break;
			case BOO:
				cons_drawchar_with_scale_3(buf, (int)'B', 100, 200, 0xffffffff, 0x00000000);
				cons_drawchar_with_scale_3(buf, (int)'O', 100+24*1, 200, 0xffffffff, 0x00000000);	
				hit = check_hit();
				cons_drawchar_with_scale_3(buf, (int)'O', 100+24*2, 200, 0xffffffff, 0x00000000);			
				break;
			case MISS: 
				cons_drawchar_with_scale_3(buf, (int)'M', 100, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'I', 100+24*1, 200, 0xffffffff, 0x00000000);
				hit = check_hit();
				cons_drawchar_with_scale_3(buf, (int)'S', 100+24*2, 200, 0xffffffff, 0x00000000);			
				cons_drawchar_with_scale_3(buf, (int)'S', 100+24*3, 200, 0xffffffff, 0x00000000);
				break;
			default:
				break;
		}
		
		buf = multibuf_flip(bufs);
	}
	printf("MARVELOUSES: %d, PERFECTS: %d, GREATS: %d, GOODS: %d, BOOS: %d, MISSES: %d\r\n", marvelouses, perfects, greats, goods, boos, misses);
}

int menu(struct menusong songs[], int nsongs)
{
	unsigned int *buf = multibuf_flip(bufs);
	int n;
	int song = 0;

	while (1) {
		for (n = 0; n < nsongs; n++) {
			splat_text(buf, songs[n].name, 50, 100*n+50, 0xffffffff, 0x00000000);
			splat_text(buf, songs[n].artist, 75, 100*n+75, 0xffffffff, 0x00000000);
			splat_text(buf, songs[n].prefix, 75, 100*n+100, 0xffffffff, 0x00000000);
		}
		splat_text(buf, "*", 25, 100*song+50, 0xff000000, 0x00000000);
		buf = multibuf_flip(bufs);
	}
	return song;
}

void main()
{
	int fat16_start;
	struct fat16_handle h;

	struct menusong songs[16];
	int n;

	int rv;
	struct fat16_file fd;
	
	/* Set up graphics. */
	multibuf_t multibuf;
	unsigned int *buf;

	buf = multibuf_init(&multibuf, SCREEN_WIDTH, SCREEN_HEIGHT);
	bufs = &multibuf;

	printf("Reading partition table... ");
	fat16_start = fat16_find_partition();
	if (fat16_start < 0)
	{
		puts("no FAT16 partition found!");
		return;
	}
	printf("found starting at sector %d.\r\n", fat16_start);
	
	printf("Opening FAT16 partition... ");
	if (fat16_open(&h, fat16_start) < 0)
	{
		puts("FAT16 boot sector read failed!");
		return;
	}
	puts("OK");

	printf("Opening menu file... ");
	if (fat16_open_by_name(&h, &fd, "MENU    TXT") == -1) {
		printf("not found?\r\n");
		return;
	}
	rv = fat16_read(&fd, songs, sizeof(songs));
	if (rv < 0) {
		printf("error reading initial song data (%d)\r\n", rv);
		return;
	}
	printf("read %d bytes\r\n", rv);

	int nsongs = rv / sizeof(struct menusong);
	for (n = 0; n < nsongs; n++) {
		songs[n].prefix[8] = '\0';
	}

	buf = multibuf_flip(bufs);

	while (1) {
		int s = menu(songs, nsongs);

		game(&h, "HAPPY   ");
	}
}

