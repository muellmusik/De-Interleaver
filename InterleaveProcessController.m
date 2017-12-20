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

#import "InterleaveProcessController.h"

#define kFramesToReadWrite 1024

int gIndex = 0, gRunning = 0, numOutputFiles;
double gLongestRecipPct; // used for updating the progress bar

@implementation InterleaveProcessController

- (void)awakeFromNib {
	// force multi-threaded mode
	[NSThread detachNewThreadSelector:@selector(self) toTarget:@"Dummy Object" withObject:nil]; 
	
	pthread_mutex_init(&mutex, NULL);
	
	channelOrderArray = [[NSMutableArray alloc] init];
	[channelOrderTable registerForDraggedTypes: [NSArray arrayWithObjects:NSStringPboardType, NSFilenamesPboardType, nil]];
	
	// toolbar
	toolBar = [[NSToolbar alloc] initWithIdentifier:@"toolbar"];
	[toolBar setAllowsUserCustomization:NO];
	[toolBar setShowsBaselineSeparator:NO];
	[toolBar setDelegate: self];
	[mainWindow setToolbar:toolBar];
	[mainWindow setOpaque:NO];
	
	[mainWindow setBackgroundColor:[NSColor colorWithCalibratedWhite:0.87 alpha:1]];
	
	types = [NSDictionary dictionaryWithObjectsAndKeys:
					[NSNumber numberWithInt: SF_FORMAT_WAV], @"wav",
					[NSNumber numberWithInt: SF_FORMAT_CAF], @"caf",
					[NSNumber numberWithInt: SF_FORMAT_AIFF], @"aiff", nil];
	[types retain];
}

- (IBAction)buttonPressed:(id)sender
{
	// need to check states
	if([sender state] == NSOffState) {
		NSLog(@"Cancel Pressed");
		lock();
		gRunning = 0;
		unlock();
	} else if([sender state] == NSOnState) {
	
		lock();
		gIndex = 0;
		gRunning = 1; // set global runflag
		unlock();
	
		// start a timer to update the progress bar
		NSTimer* timer;
		timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(updateProgressBar:) userInfo:nil repeats:YES];
		[self performSelector:operation];
	}
}

- (IBAction)deinterleave:(id)sender
{
	operation = @selector(spawnDeinterleaveThread);
	NSInteger result;
    NSOpenPanel *op = [NSOpenPanel openPanel];	
    [op setAllowsMultipleSelection:NO];
	result = [op runModal];
	if (result == NSFileHandlingPanelOKButton) {
        NSArray *filesToOpen = [op URLs];
		NSLog(@"%@", [filesToOpen description]);
        int i;
        
		inputinfo.format = 0;
		if(deIntFilePath != NULL) [deIntFilePath release];
		deIntFilePath = [[[filesToOpen objectAtIndex:0] path] retain];
		NSLog(@"deint path: %@", deIntFilePath);
		inputfile = sf_open([deIntFilePath fileSystemRepresentation], SFM_READ, &inputinfo);
		if(inputfile == NULL) {
			
			NSLog(@"%@", [NSString stringWithFormat: @"File %@ failed to open", deIntFilePath]);
			[self makeWarningWithText: [NSString stringWithFormat: @"File %@ failed to open!", deIntFilePath]];
			
			return;
		}
		if(inputinfo.channels <= 1) {
			
			NSLog(@"%@", [NSString stringWithFormat: @"Input File %@ is not multichannel!", deIntFilePath]);
			[self makeWarningWithText: [NSString stringWithFormat: @"Input File %@ is not multichannel!", deIntFilePath]];
			
			closeSNDFiles(&(inputfile), 1); // close the file already open
			return;
		}
		
		// set array for TableView		
		[channelOrderArray removeAllObjects];
		
		for(i=0; i < inputinfo.channels; i++) {
			[channelOrderArray addObject:[[[deIntFilePath stringByDeletingPathExtension] stringByAppendingFormat: @"-%i", i + 1] lastPathComponent]];
		}
		[channelOrderTable reloadData];
		
		numOutputFiles = inputinfo.channels;
		[startCancelButton setEnabled: YES];
		[startCancelButton setState: NSOffState];
		[mainWindow makeFirstResponder: startCancelButton];
		[startCancelButton display];
		
		[fileColumn setEditable: YES];
		[[fileColumn headerCell] setObjectValue:@"Output Filenames (Double-Click to Edit)"];
	}
}

- (void)spawnDeinterleaveThread {
	
	[self setViewEnabledStatusRunning:[NSNumber numberWithBool: YES]];

	// saving stuff
	// use an open panel here as we just want to get a directory
	NSOpenPanel *sp;
	
	sp = [NSOpenPanel openPanel];
	
	/* set up new attributes */
	[sp setTitle: @"Set Base Path for Deinterleaved Output Files"];
	[sp setCanChooseDirectories: YES];
	[sp setCanChooseFiles: NO];
	[sp setAllowsMultipleSelection: NO];
	//[sp setDelegate: self]; // to check for existing files
	
	NSPopUpButton *typesMenu;
	NSRect bRect = {0, 0, 130, 30};
	
	typesMenu = [[NSPopUpButton alloc] initWithFrame:bRect pullsDown:NO];
	[typesMenu addItemsWithTitles: [types allKeys]];
	[typesMenu selectItemWithTitle:@"aiff"];
	
	[typesMenu setTarget: self];
	[typesMenu setAction: @selector(setExtension:)];
	
	NSBox *box = [NSBox new];
	[box setTitle: @"Output File Format"];
	[box setTitlePosition: NSAtTop];
	[box setBorderType: NSNoBorder];
	[box addSubview: typesMenu];
	[box sizeToFit];
	[box setAutoresizingMask: NSViewNotSizable];    
	
	[sp setAccessoryView: box];
	
	// default output format is input format
	NSString *extension = [deIntFilePath pathExtension];
	if([extension isEqualToString: @"aif"]) extension = @"aiff";
	[typesMenu selectItemWithTitle: extension];
	
	
	// display the NSSavePanel
	NSInteger runResult;
	runResult = [sp runModal];
	
	if (runResult == NSFileHandlingPanelOKButton) {
		NSString *filename = [[sp URL] path];
		NSLog(@"outputdir: %@", filename);
		switch([self noOverwritesInDir:filename usingPathExtension:[typesMenu titleOfSelectedItem]]) {
			case 0:
				[self spawnDeinterleaveThread];
				return;
			case 2:
				[self setViewEnabledStatusRunning:[NSNumber numberWithBool: NO]];
				return;
		}
		[textField setStringValue:[NSString stringWithFormat: @"Deinterleaving File: %@", [deIntFilePath lastPathComponent]]];
		[textField display];
		
		NSDictionary *params = @{ @"type" : [typesMenu titleOfSelectedItem], @"filename" : filename};
		[NSThread detachNewThreadSelector: @selector(doDeinterleave:) toTarget: self withObject: params];
		
	} else {
		lock();
		gRunning = 0;
		unlock();
		[startCancelButton setNextState];
		[mainWindow display];
	}
}

- (void)doDeinterleave:(NSDictionary*)params
{
	NSAutoreleasePool *autoreleasepool = [[NSAutoreleasePool alloc] init];
	NSString *type = [params objectForKey:@"type"];
	NSString *filename = [params objectForKey:@"filename"];
	int count = inputinfo.channels;
	SF_INFO outfileinfos[count];
	SNDFILE* outputfiles[count];
	
	int inputSubtype, outMajorFormat, outformat;
	SF_INFO testInfo;
	inputSubtype = inputinfo.format & SF_FORMAT_SUBMASK;
	
	outMajorFormat = [[types objectForKey: type] intValue];
	outformat = outMajorFormat | inputSubtype; // take sample format of first input file
	testInfo.format = outformat;
	testInfo.samplerate = inputinfo.samplerate;
	testInfo.channels = 1;
	// test for valid format
	if(!sf_format_check(&testInfo)) {
		outformat = outMajorFormat | SF_FORMAT_FLOAT; // all output formats support this
		[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: @"Input sample format not supported!\nUsing 32 bit float instead." waitUntilDone:YES];
	}
	
	NSMutableArray *outpaths = [NSMutableArray arrayWithCapacity: count];
	for (int i=0; i<count; i++) {
		SF_INFO thisInfo;
		thisInfo.format = outformat;
		thisInfo.channels = 1;
		thisInfo.samplerate = inputinfo.samplerate;
		
		NSString *outpath = [[filename stringByAppendingPathComponent:[channelOrderArray objectAtIndex:i]]
							 stringByAppendingPathExtension:type];
		
		NSLog(@"outpath: %@", outpath);
		
		outputfiles[i] = sf_open([outpath cStringUsingEncoding:NSUTF8StringEncoding], SFM_WRITE, &thisInfo);
		if(outputfiles[i] == NULL) {
			
			NSLog(@"%@", [NSString stringWithFormat: @"Failed to open file %@ for writing.", outpath]);
			[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: [NSString stringWithFormat: @"Failed to open file %@ for writing.", outpath] waitUntilDone:YES];
			
			closeSNDFiles(outputfiles, i); // close the files already open
			[self performSelectorOnMainThread:@selector(setViewEnabledStatusRunning:)
								   withObject:[NSNumber numberWithBool: NO]
								waitUntilDone:YES];
			[self deletePaths: outpaths]; // delete created output files
			[autoreleasepool release];
			return;
		}
		[outpaths addObject: outpath];
		outfileinfos[i] = thisInfo;
	}
	
	// do the deinterleave
	int result = deinterleave(outputfiles, outfileinfos, count, inputfile, inputinfo, kFramesToReadWrite);
	
	// check for errors; could post libsndfile errors
	if(result) {[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: @"Write failed!" waitUntilDone:YES];}
	result = closeSNDFiles(outputfiles, count);
	if(result) {[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: @"Output files could not be closed!" waitUntilDone:YES];}
	result = sf_close(inputfile);
	if(result) {[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: @"Input file could not be closed!" waitUntilDone:YES];}
	
	lock();
	
	if(gRunning) {
		gRunning = 0; // immediately stop progress updates in main thread
		unlock();
		[textField performSelectorOnMainThread:@selector(setStringValue:)
									withObject:@"Done."
								 waitUntilDone:YES];
		[textField performSelectorOnMainThread:@selector(display)
									withObject:nil
								 waitUntilDone:YES];
		[self performSelectorOnMainThread:@selector(setProgessBarValue:)
							   withObject:[NSNumber numberWithDouble: 100.0]
							waitUntilDone:YES];
	} else {
		unlock();
		[textField performSelectorOnMainThread:@selector(setStringValue:)
									withObject:@"Cancelled."
								 waitUntilDone:YES];
		[textField performSelectorOnMainThread:@selector(display)
									withObject:nil
								 waitUntilDone:YES];
		[self performSelectorOnMainThread:@selector(setProgessBarValue:)
							   withObject:[NSNumber numberWithDouble: 0.0]
							waitUntilDone:YES];
		// delete cancelled output files
		[self deletePaths: outpaths];
	}
	
	[self performSelectorOnMainThread:@selector(setViewEnabledStatusRunning:)
						   withObject:[NSNumber numberWithBool: NO]
						waitUntilDone:YES];
	[self performSelectorOnMainThread:@selector(resetFileTable)
						   withObject:nil
						waitUntilDone:YES];
	
	[autoreleasepool release];
	
}


// since we're not specifying the actual path when deinterleaving, just the base
// we need this to warn users that files will be overwritten
- (int)noOverwritesInDir:(NSString *)path usingPathExtension:(NSString *)ext
{
	NSLog(@"checking for overwrites");

	int i;
	NSMutableArray *outpaths = [NSMutableArray arrayWithCapacity: numOutputFiles];
	NSMutableArray *existingFiles = [NSMutableArray arrayWithCapacity: numOutputFiles];
	for (i=0; i<numOutputFiles; i++) {	
		NSString *outpath = [[path stringByAppendingPathComponent:[channelOrderArray objectAtIndex:i]] 
			stringByAppendingPathExtension: ext];
		NSLog(@"outpath tested: %@", outpath);
		if([[NSFileManager defaultManager] fileExistsAtPath: outpath]) {
			NSLog(@"File Exists");
			[outpaths addObject: outpath];
			[existingFiles addObject: [outpath lastPathComponent]];
		}
	}
	if([outpaths count] > 0) {
		NSLog(@"Alert coming");
		NSAlert *alert = [[NSAlert alloc] init];
		[alert addButtonWithTitle:@"Replace"];
		[alert addButtonWithTitle:@"Select New Directory"];
		[alert addButtonWithTitle:@"Change Output Filenames"];
		NSString *filesString = [existingFiles description];
		NSRange range = {1, [filesString length] - 2 };
		[alert setMessageText:[NSString stringWithFormat: @"The files:\n%@\nalready exist. Do you wish to replace them?", 
			[filesString substringWithRange: range]]];
		[alert setInformativeText: [NSString stringWithFormat:
			@"Files with the same names already exist in %@. Replacing them will overwrite their current contents.", 
			[path lastPathComponent]]];
		[alert setAlertStyle:NSAlertStyleWarning];
		NSModalResponse clicked = [alert runModal];
		switch(clicked) {
			case NSAlertFirstButtonReturn:
				[self deletePaths: outpaths];
				[alert release];
				return 1;
			case NSAlertSecondButtonReturn:
				[alert release];
				return 0;
			case NSAlertThirdButtonReturn:
				[alert release];
				return 2;
		}
	} else {
		return 1;
	}
	return 1;
}

- (void)deletePaths:(NSArray *)outpaths {
	NSString *aPath;
	NSEnumerator *pathEnumerator = [outpaths objectEnumerator];
	while (aPath = [pathEnumerator nextObject]) {
		BOOL delete = [[NSFileManager defaultManager] removeItemAtPath: aPath error: nil];
		if(!delete) [self makeWarningWithText: [NSString stringWithFormat: @"Cancelled output file %@ could not be deleted!", aPath]];
	}
}

- (IBAction)interleave:(id)sender
{
	operation = @selector(spawnInterleaveThread);
	// opening stuff
	NSInteger result;
    NSOpenPanel *op = [NSOpenPanel openPanel];	
    [op setAllowsMultipleSelection:YES];
    result = [op runModal];
	if (result == NSFileHandlingPanelOKButton) {
		NSArray *filesToOpen = [op URLs];
		NSLog(@"%@", [filesToOpen description]);
		// set array for TableView
		[channelOrderArray removeAllObjects];
		[channelOrderArray addObjectsFromArray:filesToOpen];
		[channelOrderTable reloadData];
		[startCancelButton setEnabled: YES];
		[startCancelButton setState: NSOffState];
		[mainWindow makeFirstResponder: startCancelButton];
		[startCancelButton display];
		[fileColumn setEditable: NO];
		[[fileColumn headerCell] setObjectValue:@"Files to Interleave (Drag to Change Channel Order)"];
	}

}

- (void)spawnInterleaveThread {
	
	NSUInteger count = [channelOrderArray count];
	if(count <= 1) {

		[self makeWarningWithText:@"Select at least two input files!"];
		[self setViewEnabledStatusRunning:[NSNumber numberWithBool: NO]];
		[mainWindow display];
		return;
	}
	
	// saving stuff
	NSSavePanel *sp;
	
	/* create or get the shared instance of NSSavePanel */
	sp = [NSSavePanel savePanel];
	
	/* set up new attributes */
	[sp setTitle: @"Set Path for Interleaved Output File"];
	[sp setAllowedFileTypes:[NSArray arrayWithObject: @"aiff"] ];
	[sp setCanSelectHiddenExtension: YES];
	
	NSPopUpButton *typesMenu;
	NSRect bRect = {0, 0, 130, 30};
	
	typesMenu = [[NSPopUpButton alloc] initWithFrame:bRect pullsDown:NO];
	[typesMenu addItemsWithTitles: [types allKeys]];
	[typesMenu selectItemWithTitle:@"aiff"];
	
	[typesMenu setTarget: self];
	[typesMenu setAction: @selector(setExtension:)];
	
	NSBox *box = [NSBox new];
	[box setTitle: @"Output File Format"];
	[box setTitlePosition: NSAtTop];
	[box setBorderType: NSNoBorder];
	[box addSubview: typesMenu];
	[box sizeToFit];
	[box setAutoresizingMask: NSViewNotSizable];    
	
	[sp setAccessoryView: box];
	
	// make a plausible initial output file name
	NSString *startingName = [[[[channelOrderArray objectAtIndex:0] path] lastPathComponent] stringByDeletingPathExtension];
	NSRange lastCharRange = NSMakeRange([startingName length] - 1, 1);
	if(([startingName compare:@"L" options:NSCaseInsensitiveSearch range:lastCharRange] == NSOrderedSame) ||
	   ([startingName compare:@"0" options:NSLiteralSearch range:lastCharRange] == NSOrderedSame) ||
	   ([startingName compare:@"1" options:NSLiteralSearch range:lastCharRange] == NSOrderedSame)
	   ) {
		startingName = [startingName substringToIndex: [startingName length] - 1];
	}
	startingName = [[startingName stringByAppendingString:@"-int"] stringByAppendingPathExtension:@"aiff"];
	// display the NSSavePanel
	NSInteger runResult;
	runResult = [sp runModal];

	// if successful, save file under designated name */
	if (runResult == NSFileHandlingPanelOKButton) {
		
		[self setViewEnabledStatusRunning:[NSNumber numberWithBool: YES]];
		
		NSString *filename = [[sp URL] path];

		[textField setStringValue:[NSString stringWithFormat: @"Interleaving File: %@", [filename lastPathComponent]]];
		[textField display];
		
		NSDictionary *params = @{ @"type" : [typesMenu titleOfSelectedItem], @"filename" : filename, @"count" : [NSNumber numberWithUnsignedLong:count]};
		[NSThread detachNewThreadSelector: @selector(doInterleave:) toTarget: self withObject: params];

	} else {
		lock();
		gRunning = 0;
		unlock();

		[startCancelButton setNextState];
		[mainWindow display];
	}
}

- (void)doInterleave:(NSDictionary *)params {
	
	NSAutoreleasePool *autoreleasepool = [[NSAutoreleasePool alloc] init];
	NSString *type = [params objectForKey:@"type"];
	NSString *filename = [params objectForKey:@"filename"];
	int i, count = [[params objectForKey:@"count"] intValue];
	
	SNDFILE* inputfiles[count];
	SF_INFO inputinfos[count];
	for (i=0; i<count; i++) {
		SF_INFO thisInfo;
		thisInfo.format = 0;
		NSString *aFile = [[channelOrderArray objectAtIndex:i] path];
		inputfiles[i] = sf_open([aFile cStringUsingEncoding:NSUTF8StringEncoding], SFM_READ, &thisInfo);
		if(inputfiles[i] == NULL) {
			
			NSLog(@"%@", [NSString stringWithFormat: @"File %@ failed to open", aFile]);
			[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: [NSString stringWithFormat: @"File %@ failed to open!", aFile] waitUntilDone:YES];
			
			closeSNDFiles(inputfiles, i); // close the files already open
			[self performSelectorOnMainThread:@selector(setViewEnabledStatusRunning:)
								   withObject:[NSNumber numberWithBool: NO]
								waitUntilDone:YES];
			return;
		}
		if(thisInfo.channels != 1) {
			
			NSLog(@"%@", [NSString stringWithFormat: @"Input File %@ is multichannel!", aFile]);
			[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: [NSString stringWithFormat: @"Input File %@ is multichannel!", aFile] waitUntilDone:YES];
			
			closeSNDFiles(inputfiles, i + 1); // close the files already open
			[self performSelectorOnMainThread:@selector(setViewEnabledStatusRunning:)
								   withObject:[NSNumber numberWithBool: NO]
								waitUntilDone:YES];
			return;
		}
		inputinfos[i] = thisInfo;
	}
	
	// set parameters for info
	SF_INFO outfileinfo;
	
	int inputSubtype, outMajorFormat, outformat;
	inputSubtype = inputinfos[0].format & SF_FORMAT_SUBMASK;
	
	outMajorFormat = [[types objectForKey: type] intValue];
	outformat = outMajorFormat | inputSubtype; // take sample format of first input file
	outfileinfo.format = outformat;
	outfileinfo.samplerate = inputinfos[0].samplerate;
	outfileinfo.channels = count;
	
	if(!sf_format_check(&outfileinfo)) {
		outfileinfo.format = outMajorFormat | SF_FORMAT_FLOAT; // all output formats support this
		[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: @"Input sample format not supported!\nUsing 32 bit float instead." waitUntilDone:YES];
	}
	
	SNDFILE* outfile = sf_open([filename cStringUsingEncoding:NSUTF8StringEncoding], SFM_WRITE, &outfileinfo);
	
	if(outfile == NULL) {
		
		NSLog(@"%@", [NSString stringWithFormat: @"File %@ failed to open", filename]);
		[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: [NSString stringWithFormat: @"File %@ failed to open!", filename] waitUntilDone:YES];
		
		[self performSelectorOnMainThread:@selector(setViewEnabledStatusRunning:)
							   withObject:[NSNumber numberWithBool: NO]
							waitUntilDone:YES];
		[autoreleasepool release];
		return;
	}
	
	// do the interleave
	int result = interleave(inputfiles, inputinfos, count, outfile, outfileinfo, kFramesToReadWrite);
	
	// check for errors; could post libsndfile errors
	if(result) {[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: @"Write failed!" waitUntilDone:YES];}
	result = closeSNDFiles(inputfiles, count);
	if(result) {[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: @"Input files could not be closed!" waitUntilDone:YES];}
	result = sf_close(outfile);
	if(result) {[self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: @"Output file could not be closed!" waitUntilDone:YES];}
	
	lock();
	if(gRunning) {
		gRunning = 0; // immediately stop progress updates in main thread
		unlock();
		[textField performSelectorOnMainThread:@selector(setStringValue:)
									withObject:@"Done."
								 waitUntilDone:YES];
		[textField performSelectorOnMainThread:@selector(display)
									withObject:nil
								 waitUntilDone:YES];
		[self performSelectorOnMainThread:@selector(setProgessBarValue:)
							   withObject:[NSNumber numberWithDouble: 100.0]
							waitUntilDone:YES];
	} else {
		NSLog(@"Set UI Cancelled");
		unlock();
		[textField performSelectorOnMainThread:@selector(setStringValue:)
									withObject:@"Cancelled."
								 waitUntilDone:YES];
		[textField performSelectorOnMainThread:@selector(display)
									withObject:nil
								 waitUntilDone:YES];
		[self performSelectorOnMainThread:@selector(setProgessBarValue:)
							   withObject:[NSNumber numberWithDouble: 0.0]
							waitUntilDone:YES];
		// delete cancelled output file
		BOOL delete = [[NSFileManager defaultManager] removeItemAtPath: filename error: nil];
		if(!delete) [self performSelectorOnMainThread:@selector(makeWarningWithText:) withObject: @"Cancelled output file could not be deleted!" waitUntilDone:YES];
	}
	[self performSelectorOnMainThread:@selector(setViewEnabledStatusRunning:)
						   withObject:[NSNumber numberWithBool: NO]
						waitUntilDone:YES];
	[self performSelectorOnMainThread:@selector(resetFileTable)
						   withObject:nil
						waitUntilDone:YES];
	
	[autoreleasepool release];
}

- (void)setExtension:(id)fileTypeMenu {
    NSSavePanel *panel = (NSSavePanel *)[fileTypeMenu window];
	[panel setAllowedFileTypes:[NSArray arrayWithObject: [fileTypeMenu titleOfSelectedItem]] ];
}

- (void)makeWarningWithText:(NSString *)text {
	NSAlert *alert = [[NSAlert alloc] init];
	[alert addButtonWithTitle:@"OK"];
	[alert setMessageText:text];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert runModal];
	[alert release];
}

- (void)updateProgressBar:(NSTimer*)timer {
	// stop the timer if done
	lock();
	if(!gRunning) {
		unlock();
		NSLog(@"Timer to be invalidated");
		[timer invalidate];
	} else {
		double newval = (double)gIndex * gLongestRecipPct;
		unlock();
		[progressBar setDoubleValue: newval];
		[progressBar display];
	}
}

// used for setting values when done or cancelled
// can't call on progressBar directly since performSelectorOnMainThread needs an id
-(void)setProgessBarValue:(NSNumber *)val {
	[progressBar setDoubleValue: [val doubleValue]];
	[progressBar display];
}

-(void)setViewEnabledStatusRunning:(NSNumber *)flag {
	BOOL isRunning = [flag boolValue];
	[interleaveMenuItem setEnabled: !isRunning];
	[deinterleaveMenuItem setEnabled: !isRunning];
	[startCancelButton setEnabled: isRunning];
	[startCancelButton display];
	[mainWindow display];
}

-(void)resetFileTable {
	[fileColumn setEditable: NO];
	[[fileColumn headerCell] setObjectValue:@"Filename"];
	[channelOrderArray removeAllObjects];
	[channelOrderTable reloadData];
}

// The data-source protocol methods
- (NSUInteger)numberOfRowsInTableView:(NSTableView *)aTable
{
	return ([channelOrderArray count]);
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
    NSParameterAssert(rowIndex >= 0 && rowIndex < [channelOrderArray count]);
	if([[aTableColumn identifier] isEqualToString:@"Channel"]) { return [NSString stringWithFormat:@"%i", rowIndex + 1]; }
	
    return [channelOrderArray objectAtIndex:rowIndex];
}

- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)anObject forTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
	[channelOrderArray replaceObjectAtIndex:rowIndex withObject:anObject];
}

// drag and drop
- (BOOL)tableView:(NSTableView *)tv writeRowsWithIndexes:(NSIndexSet *)rowIndices toPasteboard:(NSPasteboard*)pboard 
{
    // Copy the row numbers to the pasteboard.
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:rowIndices];
    [pboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:self];
    [pboard setData:data forType:NSStringPboardType];
    return YES;
}

- (BOOL)tableView:(NSTableView *)aTableView acceptDrop:(id <NSDraggingInfo>)info 
			  row:(int)row dropOperation:(NSTableViewDropOperation)operation
{
    NSPasteboard* pboard = [info draggingPasteboard];
	
	// a file was dropped
	if ( [[pboard types] containsObject:NSFilenamesPboardType] ) {
        NSArray *files = [pboard propertyListForType:NSFilenamesPboardType];
        // Perform operation using the list of files
		NSLog(@"Got a file(s): %@", files);
		return YES;
    }
	
	// Or a row was dragged
    NSData* rowData = [pboard dataForType:NSStringPboardType];
    NSIndexSet* rowIndexes = [NSKeyedUnarchiver unarchiveObjectWithData:rowData];
    NSUInteger dragRow = [rowIndexes firstIndex];
	
    NSString* path = [channelOrderArray objectAtIndex:dragRow];
	[channelOrderArray removeObjectAtIndex:dragRow];
	int newIndex;
	if(dragRow > row) {
		newIndex = row;
	} else {
		newIndex = row - 1;
	}
	[channelOrderArray insertObject:path atIndex:newIndex];
	[channelOrderTable reloadData];
	[channelOrderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:newIndex] byExtendingSelection:NO];
	return YES;
}

// only allow drop between rows
- (NSDragOperation) tableView: (NSTableView*) tableView
                 validateDrop: (id ) info
                  proposedRow: (int) row
        proposedDropOperation: (NSTableViewDropOperation) op
{
    int result = NSDragOperationNone;
	
    if (op == NSTableViewDropAbove) {
        result = NSDragOperationMove;
    }
	
    return (result);
	
}

// toolbar

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
	return [NSArray arrayWithObjects:NSToolbarFlexibleSpaceItemIdentifier, @"intTBItem", @"deintTBItem", nil];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
	return [NSArray arrayWithObjects:@"intTBItem", NSToolbarFlexibleSpaceItemIdentifier, @"deintTBItem", nil];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag
{
	NSImage* tbImage;
	NSToolbarItem* item;
	if([itemIdentifier isEqualToString:@"deintTBItem"]) {
		tbImage = [NSImage imageNamed: @"deinttb.pdf"];
		if(tbImage) {
			item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
			[item setImage: tbImage];
			[item setLabel: @"Deinterleave"];
			[item setToolTip: @"Deinterleave a multichannel file to mono files"];
			[item setAction:@selector(deinterleave:)];
			[item setTarget:self];
			return item;
		}
	} else if([itemIdentifier isEqualToString:@"intTBItem"]) {
		tbImage = [NSImage imageNamed: @"inttb.pdf"];
		if(tbImage) {
			item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
			[item setImage: tbImage];
			[item setLabel: @"Interleave"];
			[item setToolTip: @"Interleave a number of mono files into a multichannel file"];
			[item setAction:@selector(interleave:)];
			[item setTarget:self];
			return item;
		}
	}
	return nil;
}

// disable while running
- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem
{
	if(gRunning) return NO;
	return YES;
}
@end

// Might want to port this or a commandline version
// so keep these as separate functions for easy reuse
int interleave(SNDFILE* inputfiles[], SF_INFO inputinfos[], int numFiles, SNDFILE* outfile, SF_INFO outfileinfo, int framesToRead) {
	
	int i, j, longest = 0;
	sf_count_t k;
	for(i = 0; i < numFiles; i++) {
		sf_count_t size;
		size = inputinfos[i].frames;
		if((int)size > longest) longest = (int)size;
	}
	
	lock();
	gLongestRecipPct = 100.0 / (double)longest;
	unlock();
	for(i=0; i < longest; i = i + framesToRead) {
		
		lock();
		gIndex = i; // update global index
		
		if(!gRunning) {
			unlock();
			break; // exit the loop if cancelled
		}
		unlock();
		
		// adjust for smaller than framesToRead if needed
		int thisRead = (i + framesToRead) > longest ? longest - i : framesToRead;
		float interleaved[numFiles * thisRead]; 
		for(j=0; j < numFiles; j++) {
			float channel[thisRead];
			sf_count_t framesRead = sf_readf_float(inputfiles[j], channel, (sf_count_t)thisRead);
			
			// check results and zeropad if needed
			if(framesRead < thisRead) {
				for(k=framesRead; k < thisRead; k++) channel[k] = 0.0;
			}
			for(k=0; k < thisRead; k++) {
				interleaved[k * numFiles + j] = channel[k];
			}
		}
		sf_count_t framesWritten = sf_writef_float(outfile, interleaved, (sf_count_t)(thisRead));
		if((int)framesWritten < (thisRead)) {
			printf("Warning! Write failed!\n");
			return(1);
		}
	}
	
	return(0);
	// closing is the responsibility of the calling function
}

int deinterleave(SNDFILE* outputfiles[], SF_INFO outputinfos[], int numFiles, SNDFILE* infile, SF_INFO infileinfo, int framesToWrite) {
	
	int i, j, k, length;
	length = (int)infileinfo.frames; // each output file will be this long
	
	lock();
	gLongestRecipPct = 100.0 / (double)length;
	unlock();
	
	for(i=0; i < length; i = i + framesToWrite) {
		
		lock();
		gIndex = i; // update global index
		
		if(!gRunning) {
			unlock();
			break; // exit the loop if cancelled
		}
		unlock();
		
		// adjust for smaller than framesToWrite if needed
		int thisRead = (i + framesToWrite) > length ? length - i : framesToWrite;
		//int thisRead = (int)infileinfo.channels * thisWrite;
		float interleaved[(int)infileinfo.channels * thisRead]; 
		sf_count_t framesRead = sf_readf_float(infile, interleaved, (sf_count_t)thisRead);
		
		if(framesRead < thisRead) {
			printf("Warning! Read failed!\n");
			return(1);
		}
		for(j=0; j < numFiles; j++) {
			float channel[thisRead];
			
			for(k=0; k < thisRead; k++) {
				channel[k] = interleaved[k * numFiles + j];
			}
			
			sf_count_t framesWritten = sf_writef_float(outputfiles[j], channel, (sf_count_t)thisRead);
			if((int)framesWritten < thisRead) {
				printf("Warning! Write failed!\n");
				return(1);
			}
		}
	}
	return(0);
	// closing is the responsibility of the calling function
}

int closeSNDFiles(SNDFILE* files[], int numFiles) {
	int i, result;
	for(i=0; i < numFiles; i++) {
		result = sf_close(files[i]);
		if(result) return result;
	}
	return(0);
}
