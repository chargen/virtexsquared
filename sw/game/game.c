#include "keyhelp.h"
#include "audio.h"
#include "fat16.h"
#include "minilib.h"
#include "accel.h"
#include "malloc.h"
#include "multibuf.h"
#include "imgres.h"

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
#define SAMPLE_TO_VIDEO_OFFSET 5800

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

void cons_drawchar_with_scale_3(unsigned int *buf, int c, int x, int y, int fg, int bg)
{
	int xx, yy;
	int i, j;
	buf = buf + (y*SCREEN_WIDTH+x);
	
	for (yy = 0; yy < 8; yy++) 
		for (xx = 0; xx < 8; xx++) 
			for (i = 0; i < 3; i++) {
				for (j = 0; j < 3; j++)
					buf[(yy*3+j) * SCREEN_WIDTH + (7 - (xx*3+i))] = ((chars[c*8 + yy] >> xx) & 1) ? fg : bg;
				audio_samples_played();
			}
}

multibuf_t *bufs;

void splat_text(unsigned int *buf, char* string, int x, int y, int fg, int bg)
{
	while (*string != '\0') {
		cons_drawchar_with_scale_3(buf, (int)(*string), x, y, fg, bg);
		string++;
		x += 24;
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
	
	accel_fill(buf, 0x00000000, SCREEN_WIDTH*SCREEN_HEIGHT);

	cons_drawchar_with_scale_3(buf, (int)'L', 200+24*0, 300, gencol(c+10), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'o', 200+24*1, 300, gencol(c+20), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'a', 200+24*2, 300, gencol(c+30), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'d', 200+24*3, 300, gencol(c+40), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'i', 200+24*4, 300, gencol(c+50), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'n', 200+24*5, 300, gencol(c+60), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'g', 200+24*6, 300, gencol(c+70), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'.', 200+24*7, 300, gencol(c+80), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'.', 200+24*8, 300, gencol(c+90), 0x000000);
	cons_drawchar_with_scale_3(buf, (int)'.', 200+24*9, 300, gencol(c+100), 0x000000);
	c += 10;

	buf = multibuf_flip(bufs);

}

unsigned int *load_audio(struct fat16_handle *h, int *length, char *filename, void **buf)
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
	if (buf)
		*buf = p;
	
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

void frobulate(char *j, int i)
{
	j[4] = i + '0';
}

int resources_loaded = 0;

struct img_resource *left_arrows[16];
struct img_resource *down_arrows[16];
struct img_resource *up_arrows[16];
struct img_resource *right_arrows[16];

struct img_resource *left_spot[2];
struct img_resource *right_spot[2];
struct img_resource *up_spot[2];
struct img_resource *down_spot[2];

struct img_resource *fantastic, *perfect, *great, *good, *boo, *miss;

void res_load(struct fat16_handle *h)
{
	int i, j;
	
	if (resources_loaded)
		return;
	
	resources_loaded = 1;
	
	for (i = 0; i < 4; i++)
	{
		char *_names[16] = { "LEFT_4  RES", "LEFT_16 RES", "LEFT_8  RES", "LEFT_4  RES",
		                    "RIGH_4  RES", "RIGH_16 RES", "RIGH_8  RES", "RIGH_4  RES",
		                    "UPUP_4  RES", "UPUP_16 RES", "UPUP_8  RES", "UPUP_4  RES",
		                    "DOWN_4  RES", "DOWN_16 RES", "DOWN_8  RES", "DOWN_4  RES" };
		char names[16][12];
		
		for (j = 0; j < 16; j++)
		{
			strcpy(names[j], _names[j]);
			frobulate(names[j], i);
		}
		
		left_arrows[0+i*4] = img_load(h, names[0]);
		left_arrows[1+i*4] = img_load(h, names[1]);
		left_arrows[2+i*4] = img_load(h, names[2]);
		left_arrows[3+i*4] = left_arrows[1];
		
		right_arrows[0+i*4] = img_load(h, names[4]);
		right_arrows[1+i*4] = img_load(h, names[5]);
		right_arrows[2+i*4] = img_load(h, names[6]);
		right_arrows[3+i*4] = right_arrows[1];
		
		up_arrows[0+i*4] = img_load(h, names[8]);
		up_arrows[1+i*4] = img_load(h, names[9]);
		up_arrows[2+i*4] = img_load(h, names[10]);
		up_arrows[3+i*4] = up_arrows[1];
		
		down_arrows[0+i*4] = img_load(h, names[12]);
		down_arrows[1+i*4] = img_load(h, names[13]);
		down_arrows[2+i*4] = img_load(h, names[14]);
		down_arrows[3+i*4] = down_arrows[1];
	}
	
	
	left_spot[0] = img_load(h, "LEFTSPOTRES");
	left_spot[1] = img_load(h, "LEFTFLASRES");
	right_spot[0] = img_load(h, "RIGHSPOTRES");
	right_spot[1] = img_load(h, "RIGHFLASRES");
	up_spot[0] = img_load(h, "UPUPSPOTRES");
	up_spot[1] = img_load(h, "UPUPFLASRES");
	down_spot[0] = img_load(h, "DOWNSPOTRES");
	down_spot[1] = img_load(h, "DOWNFLASRES");
	
	fantastic = img_load(h, "GRFANTASRES");
	perfect =   img_load(h, "GRPERFECRES");
	great =     img_load(h, "GRGREAT RES");
	good =      img_load(h, "GRGOOD  RES");
	boo =       img_load(h, "GRBOO   RES");
	miss =      img_load(h, "GRMISS  RES");
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
	void *orig;

	unsigned int *audio_mem_base;
	
	/* Set up graphics. */
	unsigned int *buf;
	
	/* Load music. */
	
	splat_loading();

	memcpy(fname, prefix, 8);
	memcpy(fname+8, "FM ", 4);
	printf("%s\r\n", fname);

	rv = load_steps(h, &song, fname);
	if (rv < 0) {
		printf("Failure loading steps! (%d)\r\n", rv);
		return;
	}

	memcpy(fname+8, "RAW", 4);

	audio_mem_base = load_audio(h, &length, fname, &orig);
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
		int s;
		
		curr_cycle = *cycleaddr;
		/*printf("Cycles: %d\r\n", curr_cycle-prev_cycle);*/
		prev_cycle = curr_cycle;

		if (qbeat < 0)
			continue;

		if (hit == NONE)	
			hit = check_hit(qbeat_round, rem);

		accel_fill(buf, 0x00000000, SCREEN_WIDTH*SCREEN_HEIGHT);
		
		samples_played = audio_samples_played()+offset;
		qbeat = (samples_played-song.delay_samps-1600)/song.samps_per_qbeat;
		rem = (samples_played-song.delay_samps-1600)%song.samps_per_qbeat;
		qbeat_round = (samples_played-song.delay_samps-1600+song.samps_per_qbeat/2)/song.samps_per_qbeat;

		s = (qbeat & 3) == 0;

		bitblt(buf,  16, 50, left_spot[s]);
		bitblt(buf,  96, 50, down_spot[s]);
		if (hit == NONE)
			hit = check_hit();
		bitblt(buf, 176, 50, up_spot[s]);
		bitblt(buf, 256, 50, right_spot[s]);
		if (hit == NONE)
			hit = check_hit();


		for (i = 7; i >= -1; i--) {
			int y = 50 + 50 * i + 50 * (song.samps_per_qbeat - rem) / song.samps_per_qbeat;
			int spot_in_beat = (qbeat + i) % 4;
			int shimmer = ((y >> 5) & 3) * 4;
			datum = song.qsteps[qbeat+i];
			if ((datum >> 3) & 1)
				bitblt(buf, 16, y, left_arrows[spot_in_beat+shimmer]);
			if ((datum >> 2) & 1)
				bitblt(buf, 96, y, down_arrows[spot_in_beat+shimmer]);
			if (hit == NONE)
				hit = check_hit();
			if ((datum >> 1) & 1)
				bitblt(buf, 176, y, up_arrows[spot_in_beat+shimmer]);
			if ((datum >> 0) & 1)
				bitblt(buf, 256, y, right_arrows[spot_in_beat+shimmer]);
			if (hit == NONE)
				hit = check_hit();
		}
		if (hit == NONE)
			hit = last_hit;
		else
			last_hit = hit;

		switch (hit) {
			case MARVELOUS:
				bitblt(buf, 32, 200, fantastic);
				break;
			case PERFECT:	
				bitblt(buf, 32, 200, perfect);
				break;
			case GREAT:
				bitblt(buf, 32, 200, great);
				break;
			case GOOD:
				bitblt(buf, 32, 200, good);
				break;
			case BOO:
				bitblt(buf, 32, 200, boo);
				break;
			case MISS: 
				bitblt(buf, 32, 200, miss);
				break;
			default:
				break;
		}
		hit = check_hit();
		
		buf = multibuf_flip(bufs);
	}

	/* show score */
	
	printf("MARVELOUSES: %d, PERFECTS: %d, GREATS: %d, GOODS: %d, BOOS: %d, MISSES: %d\r\n", marvelouses, perfects, greats, goods, boos, misses);

	char str_buf[40];
	int score_x = 175;
	accel_fill(buf, 0x00000000, SCREEN_WIDTH*SCREEN_HEIGHT);
	snprintf(str_buf, 40, "MARVELOUS    %4d", marvelouses);
	splat_text(buf, str_buf, score_x, 100, 0xffffffff, 0x00000000);
	snprintf(str_buf, 40, "PERFECT      %4d", perfects);
	splat_text(buf, str_buf, score_x, 150, 0xffffffff, 0x00000000);
	snprintf(str_buf, 40, "GREAT        %4d", greats);
	splat_text(buf, str_buf, score_x, 200, 0xffffffff, 0x00000000);
	snprintf(str_buf, 40, "GOOD         %4d", goods);
	splat_text(buf, str_buf, score_x, 250, 0xffffffff, 0x00000000);
	snprintf(str_buf, 40, "BOO          %4d", boos);
	splat_text(buf, str_buf, score_x, 300, 0xffffffff, 0x00000000);
	snprintf(str_buf, 40, "MISS         %4d", misses);
	splat_text(buf, str_buf, score_x, 350, 0xffffffff, 0x00000000);
	buf = multibuf_flip(bufs);

	while (1) {
		if ((scancode = *scancodeaddr) != 0xffffffff) {
			k = process_scancode(scancode);
			if (KH_HAS_CHAR(k) && !KH_IS_RELEASING(k)) {
				new_char = KH_GET_CHAR(k);
				if (new_char == '\n') break;
			}
		}
	}
	
	free(orig);
}

int menu(struct menusong songs[], int nsongs)
{
	unsigned int *buf = multibuf_flip(bufs);
	int n;
	int song = 0;
	volatile unsigned int* scancodeaddr = 0x85000000;
	unsigned int scancode;
	kh_type k;
	char new_char;

	int bg = 0x00000000;
	int c = 0;

	int powerby_x = 50;
	int powerby_y = 450;


	while (1) {
		accel_fill(buf, bg, SCREEN_WIDTH*SCREEN_HEIGHT);
		*buf = 0x00ff0000;
		splat_text(buf, "FailMania!", 210, 40, 0xffffffff, bg);
		for (n = 0; n < nsongs; n++) {
			splat_text(buf, songs[n].name, 70, 75*n+90, 0xffffffff, bg);
			splat_text(buf, songs[n].artist, 95, 75*n+115, 0xffffffff, bg);
		}
		splat_text(buf, "*", 35, 75*song+90, 0xff000000, 0x00000000);
		splat_text(buf, "powered by", powerby_x, powerby_y, 0xffffffff, bg);

		cons_drawchar_with_scale_3(buf, (int)'V', powerby_x+24*11+24*0, powerby_y, gencol(c+10), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'i', powerby_x+24*11+24*1, powerby_y, gencol(c+20), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'r', powerby_x+24*11+24*2, powerby_y, gencol(c+30), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'t', powerby_x+24*11+24*3, powerby_y, gencol(c+40), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'e', powerby_x+24*11+24*4, powerby_y, gencol(c+50), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'x', powerby_x+24*11+24*5, powerby_y, gencol(c+60), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'S', powerby_x+24*11+24*6, powerby_y, gencol(c+70), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'q', powerby_x+24*11+24*7, powerby_y, gencol(c+80), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'u', powerby_x+24*11+24*8, powerby_y, gencol(c+90), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'a', powerby_x+24*11+24*9, powerby_y, gencol(c+100), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'r', powerby_x+24*11+24*10, powerby_y, gencol(c+110), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'e', powerby_x+24*11+24*11, powerby_y, gencol(c+120), 0x000000);
		cons_drawchar_with_scale_3(buf, (int)'d', powerby_x+24*11+24*12, powerby_y, gencol(c+130), 0x000000);
		c += 10;

		buf = multibuf_flip(bufs); /* buf is now the real relevant framebuffer */

		while ((scancode = *scancodeaddr) != 0xffffffff) {
			k = process_scancode(scancode);
			if (KH_HAS_CHAR(k) && !KH_IS_RELEASING(k)) {
				new_char = KH_GET_CHAR(k);
				switch (new_char) {
					case 'i': song--; break;
					case 'k': song++; break;
					case '\n': goto done;
				}
				if (song < 0) song += nsongs;
				if (song >= nsongs) song -= nsongs;
			}
			break;
		}
	}
done:
	/* blank the screen to clean up after ourselves */
	accel_fill(buf, 0x00000000, SCREEN_WIDTH*SCREEN_HEIGHT);

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
	
	res_load(&h);

	int nsongs = rv / sizeof(struct menusong);
	for (n = 0; n < nsongs; n++) {
		songs[n].prefix[8] = '\0';
	}

	buf = multibuf_flip(bufs);

	while (1) {
		int s = menu(songs, nsongs);
		printf("got menu selection: %d\r\n", s);

		game(&h, songs[s].prefix);
	}
}

