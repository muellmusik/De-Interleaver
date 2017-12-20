/*
 De-Interleaver
 Copyright (c) 2006, 2017 Scott Wilson. All rights reserved.
 http://scottwilson.ca
 
 De-Interleaver's development was funded in part by a grant from the Arts 
 and Humanities Research Council of Britain, as part of the BEASTMulch project.
 
 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*/

/* InterleaveProcessController */

#import <Cocoa/Cocoa.h>
#import <sndfile.h>
#import <pthread.h>

pthread_mutex_t mutex; 

@interface InterleaveProcessController : NSObject
<NSToolbarDelegate>
{
    IBOutlet NSButton *startCancelButton;
    IBOutlet NSMenuItem *deinterleaveMenuItem;
    IBOutlet NSMenuItem *interleaveMenuItem;
    IBOutlet NSWindow *mainWindow;
    IBOutlet NSProgressIndicator *progressBar;
    IBOutlet NSTextField *textField;
	IBOutlet NSTableView *channelOrderTable;
	IBOutlet NSTableColumn *fileColumn;
	NSToolbar* toolBar;
	
	NSMutableArray *channelOrderArray;
	SEL operation;
	// for de-interleaving
	SNDFILE* inputfile;
	SF_INFO inputinfo;
	NSString *deIntFilePath;
	NSDictionary *types;
}
- (IBAction)buttonPressed:(id)sender;
- (IBAction)deinterleave:(id)sender;
- (IBAction)interleave:(id)sender;

- (void)awakeFromNib;
- (int)noOverwritesInDir:(NSString *)path usingPathExtension:(NSString *)ext;
- (void)deletePaths:(NSArray *)outpaths;
- (void)spawnInterleaveThread;
- (void)spawnDeinterleaveThread;
- (void)doDeinterleave:(NSDictionary*)params;
- (void)doInterleave:(NSDictionary*)params;
- (void)makeWarningWithText:(NSString *)text;
- (void)updateProgressBar:(NSTimer *)theTimer;
- (void)setViewEnabledStatusRunning:(NSNumber *)flag;
- (void)resetFileTable;
@end

// C worker funcs; allow for a possible cl version
int interleave(SNDFILE* inputfiles[], SF_INFO inputinfos[], int numFiles, SNDFILE* outfile, SF_INFO outfileinfo, int framesToRead);
int deinterleave(SNDFILE* outputfiles[], SF_INFO outputinfos[], int numFiles, SNDFILE* infile, SF_INFO infileinfo, int framesToWrite);
int closeSNDFiles(SNDFILE* files[], int numFiles);

// Decided early on to encapsulate locks in functions to allow for an easy conversion to or from a cmdline version. In the end
// this amounted to keeping Cocoa out of the C worker functions, which wasn't really a big deal. They probably should just be converted
// to ObjC methods and use NSLock, but the current version works fine as NSThread is just a pthread that knows somebody, and avoids
// some scoping issues that could arise.

void lock() {
	int noLock = pthread_mutex_lock(&mutex);
	if(noLock) {
		switch(noLock) { 
			case EINVAL: 
				NSLog(@"Mutex lock failed: Invalid mutex");
				break;
			case EDEADLK:
				NSLog(@"Mutex lock failed: Deadlock");
				break;
		}
	};
}

void unlock() {
	int noUnlock = pthread_mutex_unlock(&mutex);
	if(noUnlock) {
		switch(noUnlock) { 
			case EINVAL: 
				NSLog(@"Mutex unlock failed: Invalid mutex");
				break;
			case EPERM:
				NSLog(@"Mutex unlock failed: Thread does not hold lock");
				break;
		}
	};
}
