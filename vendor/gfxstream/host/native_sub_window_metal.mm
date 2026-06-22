/*
 * Copyright (C) 2024 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Metal surface support for VK_EXT_metal_surface / VK_MVK_macos_surface.
// This file is compiled on Darwin regardless of GFXSTREAM_ENABLE_HOST_GLES
// so that the Vulkan-only build path has access to CAMetalLayer.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/CALayer.h>
#import <QuartzCore/CAMetalLayer.h>

// EmuMetalView: a plain NSView backed by a CAMetalLayer.
// Used when GFXSTREAM_ENABLE_HOST_GLES=0 (vulkan-only) so that
// VkSurfaceKHR can be created via VK_EXT_metal_surface.
@interface EmuMetalView : NSView
- (CAMetalLayer *)metalLayer;
@end

@implementation EmuMetalView

- (BOOL)isOpaque { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }

- (CALayer *)makeBackingLayer {
    return [CAMetalLayer layer];
}

- (CAMetalLayer *)metalLayer {
    return (CAMetalLayer *)self.layer;
}

@end

// Returns the CAMetalLayer backing the given NSView, or nil.
// display_surface_vk.cpp calls this when VK_USE_PLATFORM_MACOS_MVK is defined.
extern "C" void* getMetalLayerFromView(void* view) {
    if (!view) return nullptr;
    NSView* nsView = (__bridge NSView*)view;

    // Fast path: view was created by createSubWindow below — it IS an EmuMetalView.
    if ([nsView isKindOfClass:[EmuMetalView class]]) {
        return [((EmuMetalView*)nsView) metalLayer];
    }

    // Fallback: any NSView whose backing layer happens to be a CAMetalLayer.
    if ([nsView.layer isKindOfClass:[CAMetalLayer class]]) {
        return nsView.layer;
    }

    return nullptr;
}

// createSubWindow / destroySubWindow / moveSubWindow for the vulkan-only path.
// These are compiled here instead of native_sub_window_cocoa.mm to avoid
// the NSOpenGL* APIs that were deprecated in macOS 14 and removed in macOS 26.
#if !GFXSTREAM_ENABLE_HOST_GLES

#include "native_sub_window.h"

EGLNativeWindowType createSubWindow(FBNativeWindowType p_window,
                                    int x, int y, int width, int height,
                                    float dpr,
                                    SubWindowRepaintCallback repaint_callback,
                                    void* repaint_callback_param,
                                    int hideWindow) {
    NSWindow* win = (__bridge NSWindow*)p_window;
    if (!win) return 0;

    // Cocoa uses a lower-left origin; convert from upper-left.
    NSRect contentRect = [win contentRectForFrameRect:[win frame]];
    int cocoaY = (int)contentRect.size.height - (y + height);
    NSRect frame = NSMakeRect(x, cocoaY, width, height);

    EmuMetalView* view = [[EmuMetalView alloc] initWithFrame:frame];
    if (!view) return 0;

    view.wantsLayer = YES;
    [view.layer setContentsScale:dpr];
    if (hideWindow) view.hidden = YES;

    [[win contentView] addSubview:view];
    [win makeKeyAndOrderFront:nil];

    return (EGLNativeWindowType)(__bridge_retained void*)view;
}

void destroySubWindow(EGLNativeWindowType win) {
    if (!win) return;
    NSView* view = (__bridge_transfer NSView*)(void*)win;
    [view removeFromSuperview];
}

int moveSubWindow(FBNativeWindowType p_window, EGLNativeWindowType p_sub_window,
                  int x, int y, int width, int height, float dpr) {
    NSWindow* win = (__bridge NSWindow*)p_window;
    NSView* view  = (__bridge NSView*)(void*)p_sub_window;
    if (!win || !view) return 0;

    [view removeFromSuperview];
    NSRect contentRect = [win contentRectForFrameRect:[win frame]];
    int cocoaY = (int)contentRect.size.height - (y + height);
    [view setFrame:NSMakeRect(x, cocoaY, width, height)];
    [view.layer setContentsScale:dpr];
    [[win contentView] addSubview:view];
    return 1;
}

void* getNativeDisplay() {
    return nullptr;  // Not needed for Metal/Vulkan path
}

#endif  // !GFXSTREAM_ENABLE_HOST_GLES
