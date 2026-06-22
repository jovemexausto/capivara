// Copyright 2024 The Android Open Source Project
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// When GFXSTREAM_ENABLE_HOST_GLES=0 this file replaces <GLES2/gl2.h>
// and <EGL/egl.h>. frame_buffer.cpp and color_buffer.cpp still reference
// GL enumerants unconditionally, so we pull them from the bundled headers
// in third_party/opengl/include — no system OpenGL library is needed.
#ifndef GLES_COMPAT_H
#define GLES_COMPAT_H

#include <cstdint>

// Bundled GL/EGL headers (no link-time dependency)
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <GLES3/gl3.h>  // GL_RGB8, GL_RGBA8, GL_R8, etc. are GLES3
#include <EGL/egl.h>
#include <EGL/eglext.h>

// GL_BGR10_A2_ANGLEX is an ANGLE-private extension not in standard headers
#ifndef GL_BGR10_A2_ANGLEX
#define GL_BGR10_A2_ANGLEX 0x6AF9
#endif

// Forward-declare ColorBufferGl so that color_buffer.cpp compiles when
// GFXSTREAM_ENABLE_HOST_GLES=0.  All uses of mColorBufferGl are already
// guarded by #if GFXSTREAM_ENABLE_HOST_GLES; this declaration satisfies
// the compiler for the nullptr guards.
namespace gfxstream {
namespace host {
namespace gl {
class ColorBufferGl;
class EmulationGl {
   public:
    EmulationGl() {}
    ~EmulationGl() {}
};
}  // namespace gl
}  // namespace host
}  // namespace gfxstream

#endif  // GLES_COMPAT_H
