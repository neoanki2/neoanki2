// CI-only display fixture. Never compiled into or bundled with NeoAnki2.
// Private CoreGraphics interface declarations adapted from Chromium's
// ui/display/mac/test/virtual_display_util_mac.mm.
// Copyright 2022 The Chromium Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google LLC nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property(strong, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong, nonatomic) id queue;
@end
@interface CGVirtualDisplayMode : NSObject
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(strong, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI, rotation;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

static BOOL ready(CGDirectDisplayID display) {
    return CGDisplayIsOnline(display) && CGMainDisplayID() == display &&
        CGDisplayPixelsWide(display) == 1440 && CGDisplayPixelsHigh(display) == 900;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        if (argc < 2 || ![environment[@"GITHUB_ACTIONS"] isEqual:@"true"] ||
            ![environment[@"RUNNER_ENVIRONMENT"] isEqual:@"github-hosted"] ||
            ![environment[@"RUNNER_OS"] isEqual:@"macOS"]) {
            fprintf(stderr, "This display fixture runs only on an isolated GitHub-hosted Mac.\n");
            return 2;
        }
        CGDirectDisplayID originals[32]; uint32_t count = 0;
        if (CGGetOnlineDisplayList(32, originals, &count) != kCGErrorSuccess || count == 0) return 3;
        CGPoint origins[32];
        for (uint32_t i = 0; i < count; i++) {
            origins[i] = CGDisplayBounds(originals[i]).origin;
            fprintf(stdout, "MACOS_REVIEW_ORIGINAL_DISPLAY=%u pixels=%zux%zu\n", originals[i],
                    CGDisplayPixelsWide(originals[i]), CGDisplayPixelsHigh(originals[i]));
        }
        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        descriptor.name = @"NeoAnki2 Store review";
        descriptor.vendorID = 505; descriptor.productID = 1;
        descriptor.serialNum = 731461; descriptor.serialNumber = 731461;
        descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
        descriptor.maxPixelsWide = 1440; descriptor.maxPixelsHigh = 900;
        descriptor.sizeInMillimeters = CGSizeMake(304.8, 190.5);
        descriptor.redPrimary = CGPointMake(0.64, 0.33);
        descriptor.greenPrimary = CGPointMake(0.30, 0.60);
        descriptor.bluePrimary = CGPointMake(0.15, 0.06);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        __attribute__((objc_precise_lifetime)) CGVirtualDisplay *virtualDisplay = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!virtualDisplay) { fprintf(stderr, "Could not create the CI virtual monitor.\n"); return 4; }
        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1440 height:900 refreshRate:60];
        settings.modes = @[mode]; settings.hiDPI = 0; settings.rotation = 0;
        if (![virtualDisplay applySettings:settings]) return 5;
        CGDirectDisplayID identifier = virtualDisplay.displayID;
        NSDate *onlineDeadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (!CGDisplayIsOnline(identifier) && onlineDeadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        if (!CGDisplayIsOnline(identifier)) return 6;
        CGDisplayConfigRef configuration;
        if (CGBeginDisplayConfiguration(&configuration) != kCGErrorSuccess) return 6;
        CGConfigureDisplayOrigin(configuration, identifier, 0, 0);
        for (uint32_t i = 0; i < count; i++) CGConfigureDisplayOrigin(configuration, originals[i], 1440 + (int)(i * 2048), 0);
        if (CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession) != kCGErrorSuccess) return 7;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (!ready(identifier) && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        int status = 8;
        if (ready(identifier)) {
            fprintf(stdout, "MACOS_STORE_REVIEW_DISPLAY=%u pixels=1440x900 main=1 virtual=1\n", identifier); fflush(stdout);
            NSTask *task = [[NSTask alloc] init]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
            NSMutableArray *arguments = [NSMutableArray array];
            for (int i = 1; i < argc; i++) [arguments addObject:[NSString stringWithUTF8String:argv[i]]];
            task.arguments = arguments;
            NSError *error = nil;
            if ([task launchAndReturnError:&error]) {
                while (task.running) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                [task waitUntilExit]; status = task.terminationStatus;
            } else { fprintf(stderr, "Review process could not start.\n"); status = 9; }
        } else fprintf(stderr, "Virtual monitor never became the actual 1440x900 main display.\n");
        // Restore original geometry before ARC releases the temporary monitor.
        if (CGBeginDisplayConfiguration(&configuration) == kCGErrorSuccess) {
            CGConfigureDisplayOrigin(configuration, identifier, 1440, 0);
            for (uint32_t i = 0; i < count; i++)
                CGConfigureDisplayOrigin(configuration, originals[i], (int)origins[i].x, (int)origins[i].y);
            CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
        }
        (void)virtualDisplay; // Keep it alive until the child and restoration finish.
        return status;
    }
}
