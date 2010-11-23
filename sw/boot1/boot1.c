#include "serial.h"
#include "sysace.h"
#include "minilib.h"
#include "audio.h"
#include "fat16.h"

void ls_callback(struct fat16_handle *h, struct fat16_dirent *de, void *priv)
{
       	if (de->name[0] == 0x00 || de->name[0] == 0x05 || de->name[0] == 0xE5 || (de->attrib & 0x48))
       		return;
        	
       	printf("  %c%c%c%c%c%c%c%c.%c%c%c %s (%d bytes)\r\n",
       	       de->name[0], de->name[1], de->name[2], de->name[3],
       	       de->name[4], de->name[5], de->name[6], de->name[7],
       	       de->ext[0], de->ext[1], de->ext[2],
       	       de->attrib & 0x10 ? "(dir)" : "(file)",
       	       de->size[0] | ((unsigned int)de->size[1] << 8) |
	       ((unsigned int)de->size[2] << 16) | ((unsigned int)de->size[3] << 24));
}

void main()
{
	int fat16_start;
	struct fat16_handle h;
	struct fat16_file fd;
	int i, j;
	
	puts("\r\n\r\nboot1 running\r\n");
	
	sysace_init();
	
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
	
	puts("Listing all files in root directory...");
	fat16_ls_root(&h, ls_callback, NULL);
	
	puts("boot1 exiting\r\n");
	
	return;
}
