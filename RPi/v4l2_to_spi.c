/*
 * v4l2_to_spi.c — capture from a UVC HDMI capture card, downscale to
 * 320x240, dither to 1bpp, and stream to an FPGA over SPI.
 *
 * Designed for a Raspberry Pi Zero 2 W. Assumes the capture card can
 * deliver YUY2 (preferred) or MJPEG. This skeleton handles YUY2 directly;
 * MJPEG requires adding a decode step (see notes at bottom).
 *
 * Build:
 *   gcc -O3 -march=armv8-a -mtune=cortex-a53 -o v4l2_to_spi v4l2_to_spi.c
 *
 * Run (as root or with appropriate permissions on /dev/video0 and /dev/spidev0.0):
 *   ./v4l2_to_spi
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>
#include <linux/videodev2.h>
#include <linux/spi/spidev.h>

/* ------------------------------------------------------------------ */
/* Configuration                                                       */
/* ------------------------------------------------------------------ */

#define VIDEO_DEV    "/dev/video0"
#define SPI_DEV      "/dev/spidev0.0"

#define CAP_WIDTH    640
#define CAP_HEIGHT   480
#define OUT_WIDTH    296
#define OUT_HEIGHT   256
#define OUT_BYTES    (OUT_WIDTH * OUT_HEIGHT / 8)   /* 9472 bytes, 1bpp */

#define SPI_SPEED_HZ 50000000   /* 50 MHz — drop to 25 MHz if unstable */
#define SPI_BITS     8
#define SPI_MODE     SPI_MODE_0

#define NUM_BUFFERS  4

/* ------------------------------------------------------------------ */
/* Globals                                                             */
/* ------------------------------------------------------------------ */

struct buffer {
    void   *start;
    size_t  length;
};

static int             video_fd = -1;
static int             spi_fd   = -1;
static struct buffer   buffers[NUM_BUFFERS];
static uint8_t         gray_frame[CAP_WIDTH * CAP_HEIGHT];   /* full-res Y plane */
static uint8_t         scaled_frame[OUT_WIDTH * OUT_HEIGHT]; /* 320x240 grayscale */
static uint8_t         packed_frame[OUT_BYTES];              /* 1bpp output */

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

static int xioctl(int fd, unsigned long req, void *arg)
{
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

static void die(const char *msg)
{
    fprintf(stderr, "FATAL: %s: %s\n", msg, strerror(errno));
    exit(1);
}

/* ------------------------------------------------------------------ */
/* V4L2 setup                                                          */
/* ------------------------------------------------------------------ */

static void v4l2_open_and_configure(void)
{
    video_fd = open(VIDEO_DEV, O_RDWR | O_NONBLOCK);
    if (video_fd < 0) die("open video device");

    struct v4l2_capability cap;
    if (xioctl(video_fd, VIDIOC_QUERYCAP, &cap) < 0) die("VIDIOC_QUERYCAP");
    if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE))
        { fprintf(stderr, "device is not a video capture device\n"); exit(1); }

    struct v4l2_format fmt = {0};
    fmt.type                = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width       = CAP_WIDTH;
    fmt.fmt.pix.height      = CAP_HEIGHT;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;   /* YUY2 */
    fmt.fmt.pix.field       = V4L2_FIELD_NONE;
    if (xioctl(video_fd, VIDIOC_S_FMT, &fmt) < 0) die("VIDIOC_S_FMT");

    if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) {
        fprintf(stderr,
            "Driver did not accept YUYV. Got fourcc 0x%08x.\n"
            "If this is MJPEG, add a decode step (see end of file).\n",
            fmt.fmt.pix.pixelformat);
        exit(1);
    }
    if (fmt.fmt.pix.width != CAP_WIDTH || fmt.fmt.pix.height != CAP_HEIGHT) {
        fprintf(stderr, "Driver gave us %ux%u instead of %ux%u — adjust CAP_* and rebuild.\n",
                fmt.fmt.pix.width, fmt.fmt.pix.height, CAP_WIDTH, CAP_HEIGHT);
        exit(1);
    }

    /* Try to set 60 fps. 50 fps isn't offered for YUYV on this card,
     * so we capture at 60 and let the FPGA pull frames at its 50 Hz CRT
     * refresh rate. Causes mild judder on motion (1 dropped/repeated
     * frame every 5 refreshes) but is otherwise transparent. */
    struct v4l2_streamparm sp = {0};
    sp.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    sp.parm.capture.timeperframe.numerator   = 1;
    sp.parm.capture.timeperframe.denominator = 60;
    xioctl(video_fd, VIDIOC_S_PARM, &sp);

    /* Request buffers */
    struct v4l2_requestbuffers req = {0};
    req.count  = NUM_BUFFERS;
    req.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(video_fd, VIDIOC_REQBUFS, &req) < 0) die("VIDIOC_REQBUFS");
    if (req.count < 2) { fprintf(stderr, "not enough buffers\n"); exit(1); }

    for (unsigned i = 0; i < req.count; i++) {
        struct v4l2_buffer buf = {0};
        buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index  = i;
        if (xioctl(video_fd, VIDIOC_QUERYBUF, &buf) < 0) die("VIDIOC_QUERYBUF");

        buffers[i].length = buf.length;
        buffers[i].start  = mmap(NULL, buf.length,
                                 PROT_READ | PROT_WRITE, MAP_SHARED,
                                 video_fd, buf.m.offset);
        if (buffers[i].start == MAP_FAILED) die("mmap");
    }

    /* Queue all buffers and start streaming */
    for (unsigned i = 0; i < req.count; i++) {
        struct v4l2_buffer buf = {0};
        buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index  = i;
        if (xioctl(video_fd, VIDIOC_QBUF, &buf) < 0) die("VIDIOC_QBUF (init)");
    }

    enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(video_fd, VIDIOC_STREAMON, &t) < 0) die("VIDIOC_STREAMON");
}

/* ------------------------------------------------------------------ */
/* SPI setup                                                           */
/* ------------------------------------------------------------------ */

static void spi_open_and_configure(void)
{
    spi_fd = open(SPI_DEV, O_RDWR);
    if (spi_fd < 0) die("open spi device");

    uint8_t mode = SPI_MODE;
    if (ioctl(spi_fd, SPI_IOC_WR_MODE, &mode) < 0) die("SPI_IOC_WR_MODE");

    uint8_t bits = SPI_BITS;
    if (ioctl(spi_fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0) die("SPI bits/word");

    uint32_t speed = SPI_SPEED_HZ;
    if (ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) < 0) die("SPI speed");

    /* Increase the spidev buffer size limit if the kernel default (4096) is
     * smaller than our 9600-byte frame. On Raspberry Pi OS this is usually
     * already configured to 65536 via /sys/module/spidev/parameters/bufsiz,
     * but check with: cat /sys/module/spidev/parameters/bufsiz
     * If it's too small, add `spidev.bufsiz=65536` to /boot/cmdline.txt. */
}

/* ------------------------------------------------------------------ */
/* Image processing                                                    */
/* ------------------------------------------------------------------ */

/*
 * YUY2 layout:  Y0 U0 Y1 V0  Y2 U1 Y3 V1  ...
 * We only want luma — every even byte. Extract straight into gray_frame.
 */
static void yuy2_extract_luma(const uint8_t *yuy2)
{
    const uint8_t *src = yuy2;
    uint8_t *dst = gray_frame;
    const uint8_t *end = dst + (CAP_WIDTH * CAP_HEIGHT);
    while (dst < end) {
        /* unrolled 8 pixels at a time — compiler will vectorize this with NEON */
        dst[0] = src[0];  dst[1] = src[2];
        dst[2] = src[4];  dst[3] = src[6];
        dst[4] = src[8];  dst[5] = src[10];
        dst[6] = src[12]; dst[7] = src[14];
        src += 16;
        dst += 8;
    }
}

/*
 * Bilinear downscale from CAP_WIDTH x CAP_HEIGHT (640x480)
 * to OUT_WIDTH x OUT_HEIGHT (296x256).
 *
 * Uses 16.16 fixed-point arithmetic — no floats, fast on Cortex-A53.
 * Steps:
 *   step_x = 640/296 ≈ 2.162 source pixels per output pixel
 *   step_y = 480/256 ≈ 1.875 source pixels per output pixel
 * Each output pixel is the bilinear blend of the 4 surrounding
 * source pixels.
 */
static void downscale_bilinear(void)
{
    const uint32_t step_x = (CAP_WIDTH  << 16) / OUT_WIDTH;
    const uint32_t step_y = (CAP_HEIGHT << 16) / OUT_HEIGHT;

    uint32_t src_y_fp = 0;
    for (int y = 0; y < OUT_HEIGHT; y++) {
        const int      sy0 = src_y_fp >> 16;
        const int      sy1 = (sy0 + 1 < CAP_HEIGHT) ? sy0 + 1 : sy0;
        const uint32_t fy  = src_y_fp & 0xFFFF;
        const uint32_t ify = 0x10000 - fy;

        const uint8_t *r0  = &gray_frame[sy0 * CAP_WIDTH];
        const uint8_t *r1  = &gray_frame[sy1 * CAP_WIDTH];
        uint8_t       *out = &scaled_frame[y * OUT_WIDTH];

        uint32_t src_x_fp = 0;
        for (int x = 0; x < OUT_WIDTH; x++) {
            const int      sx0 = src_x_fp >> 16;
            const int      sx1 = (sx0 + 1 < CAP_WIDTH) ? sx0 + 1 : sx0;
            const uint32_t fx  = src_x_fp & 0xFFFF;
            const uint32_t ifx = 0x10000 - fx;

            uint32_t top    = (r0[sx0] * ifx + r0[sx1] * fx) >> 16;
            uint32_t bottom = (r1[sx0] * ifx + r1[sx1] * fx) >> 16;
            out[x] = (uint8_t)((top * ify + bottom * fy) >> 16);

            src_x_fp += step_x;
        }
        src_y_fp += step_y;
    }
}

/*
 * 8x8 Bayer ordered dither. Cheap, branchless, and looks good on a CRT.
 * The threshold matrix has values 0..63 mapped into 0..255.
 */
static const uint8_t bayer8[8][8] = {
    {  0, 32,  8, 40,  2, 34, 10, 42 },
    { 48, 16, 56, 24, 50, 18, 58, 26 },
    { 12, 44,  4, 36, 14, 46,  6, 38 },
    { 60, 28, 52, 20, 62, 30, 54, 22 },
    {  3, 35, 11, 43,  1, 33,  9, 41 },
    { 51, 19, 59, 27, 49, 17, 57, 25 },
    { 15, 47,  7, 39, 13, 45,  5, 37 },
    { 63, 31, 55, 23, 61, 29, 53, 21 }
};

/*
 * Threshold scaled_frame to 1bpp, packing 8 pixels per byte.
 * Bit ordering: pixel 0 is MSB of byte 0 (change if your FPGA expects LSB first).
 */
static void dither_and_pack(void)
{
    uint8_t *out = packed_frame;
    for (int y = 0; y < OUT_HEIGHT; y++) {
        const uint8_t *row = &scaled_frame[y * OUT_WIDTH];
        const uint8_t *brow = bayer8[y & 7];
        for (int x = 0; x < OUT_WIDTH; x += 8) {
            uint8_t b = 0;
            for (int k = 0; k < 8; k++) {
                /* Scale Bayer 0..63 into 0..255 by multiplying by 4, then
                 * compare to the pixel value. */
                uint8_t threshold = brow[(x + k) & 7] << 2;
                if (row[x + k] > threshold) b |= (uint8_t)(0x80 >> k);
            }
            *out++ = b;
        }
    }
}

/* ------------------------------------------------------------------ */
/* SPI write                                                           */
/* ------------------------------------------------------------------ */

static void spi_send_frame(void)
{
    /* For tx-only, a plain write() is the simplest path and uses DMA
     * automatically for transfers over ~96 bytes on Raspberry Pi. */
    ssize_t n = write(spi_fd, packed_frame, OUT_BYTES);
    if (n != OUT_BYTES) {
        fprintf(stderr, "SPI short write: %zd/%d (%s)\n",
                n, OUT_BYTES, strerror(errno));
    }
}

/* ------------------------------------------------------------------ */
/* Main loop                                                           */
/* ------------------------------------------------------------------ */

static double now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

int main(void)
{
    v4l2_open_and_configure();
    spi_open_and_configure();

    fprintf(stderr, "Streaming started.\n");

    double last_report = now_ms();
    int    frames      = 0;

    for (;;) {
        /* Wait for a frame */
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(video_fd, &fds);
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        int r = select(video_fd + 1, &fds, NULL, NULL, &tv);
        if (r < 0 && errno != EINTR) die("select");
        if (r == 0) { fprintf(stderr, "select timeout\n"); continue; }

        /* Dequeue */
        struct v4l2_buffer buf = {0};
        buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        if (xioctl(video_fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) continue;
            die("VIDIOC_DQBUF");
        }

        /* Process */
        yuy2_extract_luma(buffers[buf.index].start);
        downscale_bilinear();
        dither_and_pack();
        spi_send_frame();

        /* Requeue */
        if (xioctl(video_fd, VIDIOC_QBUF, &buf) < 0) die("VIDIOC_QBUF");

        /* fps report once per second */
        frames++;
        double t = now_ms();
        if (t - last_report >= 1000.0) {
            fprintf(stderr, "%.1f fps\n", frames * 1000.0 / (t - last_report));
            frames = 0;
            last_report = t;
        }
    }

    /* (unreached) cleanup omitted */
    return 0;
}

/* ------------------------------------------------------------------ */
/* Notes                                                                */
/* ------------------------------------------------------------------ */
/*
 * If your card only offers MJPEG:
 *   Easiest path is libjpeg-turbo to decode each buffer to grayscale.
 *   In yuy2_extract_luma's place, call something like:
 *       tjDecompress2(handle, src, srcSize, gray_frame,
 *                     CAP_WIDTH, CAP_WIDTH, CAP_HEIGHT, TJPF_GRAY, 0);
 *   For best performance on the Zero 2 W, look at the V4L2 M2M JPEG
 *   decoder exposed by the VideoCore (/dev/video10..12) — it offloads
 *   decode to the GPU. That's a more involved integration; libjpeg-turbo
 *   on the CPU works for 640x480@30 in my estimation.
 *
 * Tuning:
 *   - If you see SPI errors, lower SPI_SPEED_HZ to 25_000_000.
 *   - If the dither pattern looks too "computery", swap dither_and_pack()
 *     for an Atkinson error-diffusion implementation.
 *   - If you want to flip bit ordering, change `0x80 >> k` to `1 << k`.
 *   - If your FPGA expects a frame-start signal, toggle a GPIO via
 *     /sys/class/gpio or libgpiod immediately before spi_send_frame().
 *
 * Permissions:
 *   Add your user to the `video` and `spi` groups, or run as root.
 */
