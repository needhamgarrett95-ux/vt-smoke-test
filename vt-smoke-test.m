// vt-smoke-test.m — minimal VideoToolbox H.264 encoder smoke test.
// Purpose: answer ONE question on the jailbroken iPad 7 / iOS 18.7.10:
//   does VTCompressionSession create a HARDWARE H.264 encoder and emit
//   decodable Annex-B NAL units, when run outside a foreground app?
// Usage: vt-smoke-test hw   (require hardware encoder; FAILS if none)
//        vt-smoke-test any  (allow software fallback; reports which ran)
// Writes Annex-B to vt-smoke-<mode>.h264 in the current directory.
// Exit 0 = >=10 frames encoded and file non-empty. Exit 1 = encoder failed.
// Exit 2 = ran but <10 frames / empty output (software fallback still exits 0
//          if it encoded; the caller judges speed from the log).
// Uses only public VideoToolbox / CoreMedia / CoreVideo APIs.

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

static const int kWidth  = 540;
static const int kHeight = 405;
static const int kFrames = 90;          // 3 s at 30 fps
static const int kFps    = 30;

static FILE *g_out = NULL;
static dispatch_semaphore_t g_done = NULL;
static int g_encoded = 0;
static int g_keyframes = 0;
static size_t g_bytes = 0;
static double g_firstCallback = 0;

static double now_s(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
}

// Write one AVCC sample buffer as Annex-B (SPS/PPS prepended on keyframes).
static void writeAnnexB(CMSampleBufferRef sbuf, BOOL isKeyframe,
                        CMFormatDescriptionRef fmt) {
    if (isKeyframe) {
        for (int i = 0; i < 2; i++) {
            const uint8_t *ps = NULL; size_t psSize = 0; size_t psCount = 0;
            OSStatus st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, i, &ps, &psSize, &psCount, NULL);
            if (st == noErr && ps && psSize > 0) {
                static const uint8_t start[4] = {0, 0, 0, 1};
                fwrite(start, 1, 4, g_out);
                fwrite(ps, 1, psSize, g_out);
                g_bytes += 4 + psSize;
            }
        }
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sbuf);
    if (!bb) return;
    size_t len = 0; char *ptr = NULL;
    if (CMBlockBufferGetDataPointer(bb, 0, &len, NULL, &ptr) != noErr) return;
    size_t off = 0;
    while (off + 4 <= len) {
        uint32_t nalLen = ((uint32_t)(uint8_t)ptr[off]   << 24) |
                          ((uint32_t)(uint8_t)ptr[off+1] << 16) |
                          ((uint32_t)(uint8_t)ptr[off+2] <<  8) |
                          ((uint32_t)(uint8_t)ptr[off+3]);
        off += 4;
        if (nalLen == 0 || off + nalLen > len) break;
        static const uint8_t start[4] = {0, 0, 0, 1};
        fwrite(start, 1, 4, g_out);
        fwrite(ptr + off, 1, nalLen, g_out);
        g_bytes += 4 + nalLen;
        off += nalLen;
    }
}

static void encodeCallback(void *refcon,
                           void *sourceFrameRefCon,
                           OSStatus status,
                           VTEncodeInfoFlags infoFlags,
                           CMSampleBufferRef sbuf) {
    (void)refcon; (void)sourceFrameRefCon; (void)infoFlags;
    if (status != noErr) {
        fprintf(stderr, "[cb] encode error %d\n", (int)status);
        return;
    }
    if (!sbuf || !CMSampleBufferDataIsReady(sbuf)) return;
    if (g_encoded == 0) g_firstCallback = now_s();
    BOOL isKeyframe = YES;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(atts, 0);
        isKeyframe = !CFDictionaryContainsKey(d, kCMSampleAttachmentKey_NotSync);
    }
    if (isKeyframe) g_keyframes++;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
    writeAnnexB(sbuf, isKeyframe, fmt);
    g_encoded++;
    if (g_encoded >= kFrames) dispatch_semaphore_signal(g_done);
}

static void fillFrame(CVPixelBufferRef pb, int frame) {
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    // Moving vertical bar + gradient, BGRA. Changes every frame so the
    // encoder cannot emit empty frames.
    int barX = (frame * 7) % kWidth;
    for (int y = 0; y < kHeight; y++) {
        uint8_t *row = base + y * stride;
        for (int x = 0; x < kWidth; x++) {
            uint8_t *px = row + x * 4;
            int inBar = (x >= barX && x < barX + 40);
            px[0] = (uint8_t)(inBar ? 255 : (x * 255 / kWidth));       // B
            px[1] = (uint8_t)(y * 255 / kHeight);                      // G
            px[2] = (uint8_t)(inBar ? 40  : (frame * 3 % 256));        // R
            px[3] = 255;                                               // A
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL requireHW = YES;
        const char *mode = "hw";
        if (argc > 1 && strcmp(argv[1], "any") == 0) { requireHW = NO; mode = "any"; }

        char outPath[64];
        snprintf(outPath, sizeof(outPath), "vt-smoke-%s.h264", mode);
        g_out = fopen(outPath, "wb");
        if (!g_out) { fprintf(stderr, "cannot open %s\n", outPath); return 1; }
        g_done = dispatch_semaphore_create(0);

        fprintf(stderr, "[vt-smoke] mode=%s requireHW=%d %dx%d %d frames @%d fps\n",
                mode, requireHW, kWidth, kHeight, kFrames, kFps);

        // --- 1. Create the session -------------------------------------
        CFMutableDictionaryRef spec = CFDictionaryCreateMutable(
            NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(spec,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder,
            requireHW ? kCFBooleanTrue : kCFBooleanFalse);

        VTCompressionSessionRef session = NULL;
        double t0 = now_s();
        OSStatus st = VTCompressionSessionCreate(
            NULL, kWidth, kHeight, kCMVideoCodecType_H264,
            spec, NULL, NULL, encodeCallback, NULL, &session);
        CFRelease(spec);
        fprintf(stderr, "[vt-smoke] VTCompressionSessionCreate -> %d (%.3fs)\n",
                (int)st, now_s() - t0);
        if (st != noErr || !session) {
            fprintf(stderr, "[vt-smoke] RESULT: ENCODER_CREATE_FAILED status=%d\n", (int)st);
            fclose(g_out); return 1;
        }

        // --- 2. Hardware or software? (documented read-only property) --
        CFBooleanRef usingHW = NULL;
        st = VTSessionCopyProperty(session,
            kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            kCFAllocatorDefault, &usingHW);
        if (st == noErr && usingHW) {
            fprintf(stderr, "[vt-smoke] UsingHardwareAcceleratedVideoEncoder = %s\n",
                    CFBooleanGetValue(usingHW) ? "YES" : "NO");
            CFRelease(usingHW);
        } else {
            fprintf(stderr, "[vt-smoke] UsingHardwareAcceleratedVideoEncoder query failed: %d\n", (int)st);
        }

        // --- 3. Session properties (each failure logged, none fatal) ----
        struct { CFStringRef key; const void *val; const char *name; } props[] = {
            { kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime" },
            { kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering" },
            { kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel, "ProfileLevel=Baseline" },
        };
        for (size_t i = 0; i < sizeof(props)/sizeof(props[0]); i++) {
            st = VTSessionSetProperty(session, props[i].key, props[i].val);
            fprintf(stderr, "[vt-smoke] set %s -> %d\n", props[i].name, (int)st);
        }
        SInt32 br = 500000;
        CFNumberRef brNum = CFNumberCreate(NULL, kCFNumberSInt32Type, &br);
        st = VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, brNum);
        fprintf(stderr, "[vt-smoke] set AverageBitRate=500000 -> %d\n", (int)st);
        CFRelease(brNum);
        Float64 fr = kFps;
        CFNumberRef frNum = CFNumberCreate(NULL, kCFNumberFloat64Type, &fr);
        st = VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, frNum);
        fprintf(stderr, "[vt-smoke] set ExpectedFrameRate=30 -> %d\n", (int)st);
        CFRelease(frNum);
        SInt32 kfi = 60;
        CFNumberRef kfiNum = CFNumberCreate(NULL, kCFNumberSInt32Type, &kfi);
        st = VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, kfiNum);
        fprintf(stderr, "[vt-smoke] set MaxKeyFrameInterval=60 -> %d\n", (int)st);
        CFRelease(kfiNum);
        // Low-latency rate control (iOS 15+ property; non-fatal if rejected).
        st = VTSessionSetProperty(session,
            kVTCompressionPropertyKey_EnableLowLatencyRateControl, kCFBooleanTrue);
        fprintf(stderr, "[vt-smoke] set EnableLowLatencyRateControl -> %d (non-fatal)\n", (int)st);

        st = VTCompressionSessionPrepareToEncodeFrames(session);
        fprintf(stderr, "[vt-smoke] PrepareToEncodeFrames -> %d\n", (int)st);
        // Re-check hardware flag after prepare (some encoders decide lazily).
        usingHW = NULL;
        st = VTSessionCopyProperty(session,
            kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            kCFAllocatorDefault, &usingHW);
        if (st == noErr && usingHW) {
            fprintf(stderr, "[vt-smoke] after prepare: UsingHardwareAcceleratedVideoEncoder = %s\n",
                    CFBooleanGetValue(usingHW) ? "YES" : "NO");
            CFRelease(usingHW);
        }

        // --- 4. Encode 90 synthetic BGRA frames ------------------------
        double encStart = now_s();
        for (int i = 0; i < kFrames; i++) {
            CVPixelBufferRef pb = NULL;
            st = CVPixelBufferCreate(NULL, kWidth, kHeight,
                kCVPixelFormatType_32BGRA, NULL, &pb);
            if (st != noErr || !pb) {
                fprintf(stderr, "[vt-smoke] CVPixelBufferCreate failed %d at frame %d\n", (int)st, i);
                break;
            }
            fillFrame(pb, i);
            st = VTCompressionSessionEncodeFrame(session, pb,
                CMTimeMake(i, kFps), kCMTimeInvalid, NULL, NULL, NULL);
            CVPixelBufferRelease(pb);
            if (st != noErr) {
                fprintf(stderr, "[vt-smoke] EncodeFrame failed %d at frame %d\n", (int)st, i);
                break;
            }
        }
        double encSubmit = now_s();
        fprintf(stderr, "[vt-smoke] submitted %d frames in %.3fs\n", kFrames, encSubmit - encStart);
        VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);

        // Wait for callbacks (max 30 s).
        dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC);
        long waited = dispatch_semaphore_wait(g_done, deadline);
        double end = now_s();
        fprintf(stderr, "[vt-smoke] callbacks %s (waited=%ld)\n",
                waited == 0 ? "all received" : "TIMEOUT", waited);
        if (g_encoded > 0 && g_firstCallback > 0) {
            fprintf(stderr, "[vt-smoke] first callback at %.3fs after submit start\n",
                    g_firstCallback - encStart);
        }

        double total = end - encStart;
        fprintf(stderr, "[vt-smoke] RESULT: encoded=%d keyframes=%d bytes=%zu "
                "wall=%.3fs encode_fps=%.1f avg_bytes_per_frame=%zu\n",
                g_encoded, g_keyframes, g_bytes, total,
                total > 0 ? g_encoded / total : 0,
                g_encoded > 0 ? g_bytes / g_encoded : 0);

        VTCompressionSessionInvalidate(session);
        CFRelease(session);
        fclose(g_out);

        if (g_encoded >= 10 && g_bytes > 0) {
            fprintf(stderr, "[vt-smoke] RESULT: PASS\n");
            return 0;
        }
        fprintf(stderr, "[vt-smoke] RESULT: FAIL (encoded=%d bytes=%zu)\n", g_encoded, g_bytes);
        return 2;
    }
    return 0;
}
