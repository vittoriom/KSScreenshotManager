/*
 * KSScreenshotManager.m
 *
 * Copyright (c) 2013 Kent Sutherland
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
 * Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#if CREATING_SCREENSHOTS

#import "KSScreenshotManager.h"
#import "KSScreenshotAction.h"

CGImageRef UIGetScreenImage(); //private API for getting an image of the entire screen

@interface KSScreenshotManager ()
@property(nonatomic, strong) NSMutableArray *screenshotActions;
@end

@implementation KSScreenshotManager

- (id)init
{
    if ( (self = [super init]) ) {
        NSArray *arguments = [[NSProcessInfo processInfo] arguments];
        
        //Prefer taking the last launch argument. This allows us to specify an output path when running with WaxSim.
        if ([arguments count] > 1) {
            NSString *savePath = [[arguments lastObject] stringByExpandingTildeInPath];
            
            [self setScreenshotsURL:[NSURL fileURLWithPath:savePath]];
        } else {
            NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
            
            [self setScreenshotsURL:[NSURL fileURLWithPath:documentsPath]];
        }

        _exitOnComplete = YES;
        _loggingEnabled = YES;
    }
    return self;
}

- (void)takeScreenshots
{
    [self setupScreenshotActions];
    
    if ([[self screenshotActions] count] == 0) {
        [NSException raise:NSInternalInconsistencyException format:@"No screenshot actions have been defined. Unable to take screenshots."];
    }
    
    [self takeNextScreenshot];
}

- (void)takeNextScreenshot
{
    if ([[self screenshotActions] count] > 0) {
        KSScreenshotAction *nextAction = [[self screenshotActions] objectAtIndex:0];
        
        if ([nextAction actionBlock]) {
            [nextAction actionBlock]();
        }
        
        if (![nextAction asynchronous]) {
            //synchronous actions can run immediately
            //asynchronous actions need to call actionIsReady manually
            [self actionIsReady];
        }
    } else if ([self doesExitOnComplete]) {
        exit(0);
    }
}

- (void)actionIsReady
{
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false); //spin the run loop to give the UI a chance to catch up
    
    KSScreenshotAction *nextAction = [[self screenshotActions] objectAtIndex:0];
    
    [self saveScreenshot:[nextAction name] includeStatusBar:[nextAction includeStatusBar]];
    
    if ([nextAction cleanupBlock]) {
        [nextAction cleanupBlock]();
    }
    
    [[self screenshotActions] removeObjectAtIndex:0];
    
    [self takeNextScreenshot];
}

- (void)setupScreenshotActions
{
    [NSException raise:NSInternalInconsistencyException format:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)];
}

- (void)addScreenshotAction:(KSScreenshotAction *)screenshotAction
{
    if (!_screenshotActions) {
        [self setScreenshotActions:[NSMutableArray array]];
    }
    
    [screenshotAction setManager:self];
    
    [[self screenshotActions] addObject:screenshotAction];
}

- (void)saveScreenshot:(NSString *)name includeStatusBar:(BOOL)includeStatusBar
{
    //Get image with status bar cropped out
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    BOOL isRetina = screenScale != 1.0f;
    UIWindow *mainWindow = [[UIApplication sharedApplication] keyWindow];
    UIGraphicsBeginImageContextWithOptions(mainWindow.bounds.size, NO, screenScale);
    [mainWindow drawViewHierarchyInRect:mainWindow.bounds afterScreenUpdates:YES];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    BOOL isPortrait = UIInterfaceOrientationIsPortrait(orientation);
    
    //Rotate image to match orientation
    if (!isPortrait) {
        CGSize size;
        
        if (UIInterfaceOrientationIsLandscape(orientation)) {
            size.width = [image size].height;
            size.height = [image size].width;
        } else {
            size = [image size];
        }
        
        UIGraphicsBeginImageContextWithOptions(size, YES, 1);
        
        CGContextRef context = UIGraphicsGetCurrentContext();
        
        if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
            CGContextRotateCTM(context, M_PI);
            CGContextTranslateCTM(context, -size.width, -size.height);
        } else if (orientation == UIInterfaceOrientationLandscapeLeft) {
            CGContextRotateCTM(context, M_PI_2);
            CGContextTranslateCTM(context, 0, -size.width);
        } else if (orientation == UIInterfaceOrientationLandscapeRight) {
            CGContextRotateCTM(context, -M_PI_2);
            CGContextTranslateCTM(context, -size.height, 0);
        }
        
        [image drawAtPoint:CGPointZero];
        
        image = UIGraphicsGetImageFromCurrentImageContext();
        
        UIGraphicsEndImageContext();
    }
    
    NSString *devicePrefix = nil;
    NSString *screenDensity = isRetina ? [NSString stringWithFormat:@"@%.0fx", screenScale] : @"";
    
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        CGFloat screenHeight;
        
        if ([[UIScreen mainScreen] respondsToSelector:@selector(coordinateSpace)]) {
            // Always refer to screens by the vertical height, even if the screenshot is landscape
            screenHeight = CGRectGetHeight([[[UIScreen mainScreen] coordinateSpace] convertRect:[[UIScreen mainScreen] bounds] toCoordinateSpace:[[UIScreen mainScreen] fixedCoordinateSpace]]);
        } else {
            screenHeight = CGRectGetHeight([[UIScreen mainScreen] bounds]);
        }
        
        devicePrefix = [NSString stringWithFormat:@"iphone%.0f%@", screenHeight, screenDensity];
    } else {
        devicePrefix = [NSString stringWithFormat:@"ipad%@",screenDensity];
    }
    
    NSData *data = UIImagePNGRepresentation(image);
    NSString *file = [NSString stringWithFormat:@"%@-%@-%@.png", devicePrefix, [[NSLocale currentLocale] localeIdentifier], name];
    NSURL *fileURL = [[self screenshotsURL] URLByAppendingPathComponent:file];
    NSError *error;
    
    // Create the screenshot directory if it doesn't exist already
    if (![[NSFileManager defaultManager] createDirectoryAtURL:[self screenshotsURL] withIntermediateDirectories:YES attributes:nil error:&error]) {
        if (_loggingEnabled) {
            NSLog(@"Failed to create screenshots directory: %@", error);
        }
    }
    
    if (_loggingEnabled) {
        NSLog(@"Saving screenshot: %@", [fileURL path]);
    }
    
    if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) {
        if (_loggingEnabled) {
            NSLog(@"Failed to write screenshot at %@: %@", fileURL, error);
        }
    }
}

@end

#endif
