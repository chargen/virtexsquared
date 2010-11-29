#include "keyhelp.h"
#include "audio.h"
#include "fat16.h"
#include "minilib.h"
#include "accel.h"
#include "malloc.h"

#include "left_4.c"
#include "down_4.c"
#include "up_4.c"
#include "right_4.c"
#include "left_8.c"
#include "down_8.c"
#include "up_8.c"
#include "right_8.c"
#include "left_16.c"
#include "down_16.c"
#include "up_16.c"
#include "right_16.c"
#include "left_spot.c"
#include "down_spot.c"
#include "up_spot.c"
#include "right_spot.c"

#define MAX_QBEATS 50000
#define SCREEN_WIDTH 640
#define SCREEN_HEIGHT 480

static unsigned char chars[] = {
#include "chars.inc"
};

struct stepfile {
	unsigned int len_qbeats;
	signed int samps_per_qbeat;
	signed int delay_samps;
	unsigned char qsteps[MAX_QBEATS];
};


int load_steps(struct fat16_handle * h, struct stepfile * song)
{
	int rv;
	struct fat16_file fd;
	
	printf("Opening STEPS.FM... ");
	if (fat16_open_by_name(h, &fd, "STEPS   FM ") == -1)
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

unsigned int *load_audio(struct fat16_handle * h, int *length)
{
	int rv;
	struct fat16_file fd;
	unsigned int *p;
	
	printf("Opening AUDIO.RAW... ");
	if (fat16_open_by_name(h, &fd, "AUDIO   RAW") == -1)
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
	
	rv = fat16_read(&fd, (void*)p, fd.len);
	printf("loaded! (%d bytes)\r\n", rv);
	
	if (length)
		*length = rv;
	
	return p;
}

/*
 * Double buffering
 */
struct dbuf {
	unsigned int *bufs[2];
	unsigned int *bufs_orig[2];
	int which;
};

unsigned int *dbuf_flip(struct dbuf *dbuf)
{
	volatile unsigned int *frame_start = 0x82000000;
	volatile unsigned int *frame_nread = 0x8200000c;
	*frame_start = dbuf->bufs[dbuf->which];
	unsigned int read_last = *frame_nread;
	unsigned int read;
	while ((read = *frame_nread) >= read_last) read_last = read;
	dbuf->which = !dbuf->which;
	return dbuf->bufs[dbuf->which];
}

unsigned int *dbuf_init(struct dbuf *dbuf)
{
	dbuf->bufs_orig[0] = malloc(SCREEN_WIDTH*SCREEN_HEIGHT*4 + 64);
	dbuf->bufs_orig[1] = malloc(SCREEN_WIDTH*SCREEN_HEIGHT*4 + 64);
	dbuf->bufs[0] = (unsigned int *) (((unsigned int) dbuf->bufs_orig[0] + 64) & ~63);
	dbuf->bufs[1] = (unsigned int *) (((unsigned int) dbuf->bufs_orig[1] + 64) & ~63);
	dbuf->which = 0;
	
	return dbuf_flip(dbuf);
}

#define SPRITE_DIM 64
#define OTHER_ENDIANNESS(x) (((x>>24) & 0xff) | ((x >> 8) & 0xff00) | ((x << 8) & 0xff0000) | ((x << 24) & 0xff000000))
#define DRAW_PIX(buf, img, x0, y0, y, x) if ((img)[SPRITE_DIM*(y)+(x)]&0xff000000) (buf)[SCREEN_WIDTH*(y0+y)+(x0+x)] = OTHER_ENDIANNESS((img)[SPRITE_DIM*(y)+(x)]);

void draw_note(unsigned int *buf, unsigned int x0, unsigned int y0, unsigned int *image) {
	int x, y;
	for (y = 0; y < SPRITE_DIM; y++) {
		for (x = 0; x < SPRITE_DIM; x+=8) {
			DRAW_PIX(buf, image, x0, y0, y, x+0);
			DRAW_PIX(buf, image, x0, y0, y, x+1);
			DRAW_PIX(buf, image, x0, y0, y, x+2);
			DRAW_PIX(buf, image, x0, y0, y, x+3);
			DRAW_PIX(buf, image, x0, y0, y, x+4);
			DRAW_PIX(buf, image, x0, y0, y, x+5);
			DRAW_PIX(buf, image, x0, y0, y, x+6);
			DRAW_PIX(buf, image, x0, y0, y, x+7);
		}
	}
}

void cons_drawchar_with_scale(unsigned int *buf, int c, int x, int y, int fg, int bg, int scale)
{
	int xx, yy;
	int i, j;
	buf = buf + (y*SCREEN_WIDTH+x);
	
	for (yy = 0; yy < 8; yy++)
		for (xx = 0; xx < 8; xx++)
			for (i = 0; i < scale; i++)
				for (j = 0; j < scale; j++)
					buf[(yy*scale+j) * SCREEN_WIDTH + (7 - (xx*scale+i))] = ((chars[c*8 + yy] >> xx) & 1) ? fg : bg; 
}

static struct stepfile song;

void main()
{
	int i, j;
	int length;
	int rv;

	unsigned int *audio_mem_base;

	int fat16_start;
	struct fat16_handle h;

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

	rv = load_steps(&h, &song);
	if (rv < 0) {
		printf("Failure loading steps! (%d)\r\n", rv);
		return;
	}

	audio_mem_base = load_audio(&h, &length);
	if (!audio_mem_base) {
		printf("Failure loading audio! (%d)\r\n", rv);
		return;
	}

	printf("qbeats: %d; samps_per_qbeat: %d; playing...\r\n", song.len_qbeats, song.samps_per_qbeat);

	audio_play(audio_mem_base, length, AUDIO_MODE_ONCE);

	struct dbuf double_buffer;
	unsigned int *buf;

	volatile unsigned int * scancodeaddr = 0x85000000;
	unsigned int scancode;
	kh_type k;
	char new_char;

	int l, u, d, r;
	l = 0;
	u = 0;
	d = 0;
	r = 0;

	int hit_l, hit_u, hit_d, hit_r;
	hit_l = -1;
	hit_u = -1;
	hit_d = -1;
	hit_r = -1;

	int hits = 0;
	signed int qbeat_last;

	buf = dbuf_init(&double_buffer);

	int * left_arrows[4]  = {&(left_4_img.pixel_data), &(left_16_img.pixel_data), &(left_8_img.pixel_data), &(left_16_img.pixel_data)};
	int * down_arrows[4]  = {&(down_4_img.pixel_data), &(down_16_img.pixel_data), &(down_8_img.pixel_data), &(down_16_img.pixel_data)};
	int * up_arrows[4]  = {&(up_4_img.pixel_data), &(up_16_img.pixel_data), &(up_8_img.pixel_data), &(up_16_img.pixel_data)};
	int * right_arrows[4]  = {&(right_4_img.pixel_data), &(right_16_img.pixel_data), &(right_8_img.pixel_data), &(right_16_img.pixel_data)};

	while (1) {
		signed int qbeat, rem, qbeat_round, meas_qbeat;
		char datum;
		int i;
		int lnow = l;
		int unow = u;
		int dnow = d;
		int rnow = r;
		int samples_played;
		while ((scancode = *scancodeaddr) != 0xffffffff) {
			k = process_scancode(scancode);
			if (KH_HAS_CHAR(k)) {
				new_char = KH_GET_CHAR(k);
				switch (new_char) {
					case 'j': lnow = !KH_IS_RELEASING(k); break;
					case 'i': unow = !KH_IS_RELEASING(k); break;
					case 'k': dnow = !KH_IS_RELEASING(k); break;
					case 'l': rnow = !KH_IS_RELEASING(k); break;
				}
			}
		}
		
		samples_played = audio_samples_played();
		qbeat = (samples_played-song.delay_samps-1600)/song.samps_per_qbeat;
		rem = (samples_played-song.delay_samps-1600)%song.samps_per_qbeat;
		qbeat_round = (samples_played-song.delay_samps-1600+song.samps_per_qbeat/2)/song.samps_per_qbeat;

		if (qbeat < 0)
			continue;

		if (lnow && !l) {
			if ((song.qsteps[qbeat_round] >> 3) & 1) hits++;
			hit_l = qbeat_round;
		}
		if (unow && !u) {
			if ((song.qsteps[qbeat_round] >> 2) & 1) hits++;
			hit_u = qbeat_round;
		}
		if (dnow && !d) {
			if ((song.qsteps[qbeat_round] >> 1) & 1) hits++;
			hit_d = qbeat_round;
		}
		if (rnow && !r) {
			if ((song.qsteps[qbeat_round] >> 0) & 1) hits++;
			hit_r = qbeat_round;
		}

		if (qbeat_last != qbeat) {
			qbeat_last = qbeat;
		}

		l = lnow;
		u = unow;
		d = dnow;
		r = rnow;

		accel_fill(buf, 0x00000000, SCREEN_WIDTH*SCREEN_HEIGHT);

		draw_note(buf,  25, 50, &(left_spot_img.pixel_data));
		draw_note(buf, 100, 50, &(down_spot_img.pixel_data));
		draw_note(buf, 175, 50, &(up_spot_img.pixel_data));
		draw_note(buf, 250, 50, &(right_spot_img.pixel_data));
		for (i = 7; i >= -1; i--) {
			int y = 50 + 50 * i + 50 * (song.samps_per_qbeat - rem) / song.samps_per_qbeat;
			int spot_in_beat = (qbeat + i) % 4;
			datum = song.qsteps[qbeat+i];
			if ((datum >> 3) & 1)
				draw_note(buf, 25, y, left_arrows[spot_in_beat]);
			if ((datum >> 2) & 1)
				draw_note(buf, 100, y, down_arrows[spot_in_beat]);
			if ((datum >> 1) & 1)
				draw_note(buf, 175, y, up_arrows[spot_in_beat]);
			if ((datum >> 0) & 1)
				draw_note(buf, 250, y, right_arrows[spot_in_beat]);
		}
		cons_drawchar_with_scale(buf, (int)'G', 400, 300, 0xffffffff, 0x000000, 3);
		cons_drawchar_with_scale(buf, (int)'R', 424, 300, 0xffffffff, 0x000000, 3);
		cons_drawchar_with_scale(buf, (int)'E', 448, 300, 0xffffffff, 0x000000, 3);
		cons_drawchar_with_scale(buf, (int)'A', 472, 300, 0xffffffff, 0x000000, 3);
		cons_drawchar_with_scale(buf, (int)'T', 496, 300, 0xffffffff, 0x000000, 3);

		buf = dbuf_flip(&double_buffer);
	}
}

