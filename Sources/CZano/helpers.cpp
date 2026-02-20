#include "helpers.hpp"

#ifdef __ANDROID__
#include <unistd.h>
#include <thread>
#include <android/log.h>

#define LOG_TAG "zanoc"
#define BUFFER_SIZE 1024*32

static int stdoutToLogcat(const char *buf, int size) {
    __android_log_write(ANDROID_LOG_INFO, LOG_TAG, buf);
    return size;
}

static int stderrToLogcat(const char *buf, int size) {
    __android_log_write(ANDROID_LOG_ERROR, LOG_TAG, buf);
    return size;
}

static void redirectStdoutThread(int pipe_stdout[2]) {
    char bufferStdout[BUFFER_SIZE];
    while (true) {
        int read_size = read(pipe_stdout[0], bufferStdout, sizeof(bufferStdout) - 1);
        if (read_size > 0) {
            bufferStdout[read_size] = '\0';
            stdoutToLogcat(bufferStdout, read_size);
        }
    }
}

static void redirectStderrThread(int pipe_stderr[2]) {
    char bufferStderr[BUFFER_SIZE];
    while (true) {
        int read_size = read(pipe_stderr[0], bufferStderr, sizeof(bufferStderr) - 1);
        if (read_size > 0) {
            bufferStderr[read_size] = '\0';
            stderrToLogcat(bufferStderr, read_size);
        }
    }
}

static void setupAndroidLogging() {
    static int pfdStdout[2];
    static int pfdStderr[2];

    pipe(pfdStdout);
    pipe(pfdStderr);

    dup2(pfdStdout[1], STDOUT_FILENO);
    dup2(pfdStderr[1], STDERR_FILENO);

    std::thread stdoutThread(redirectStdoutThread, pfdStdout);
    std::thread stderrThread(redirectStderrThread, pfdStderr);

    stdoutThread.detach();
    stderrThread.detach();
}

#endif // __ANDROID__

// Unique constructor name for Zano - prevents conflict with MoneroKit
__attribute__((constructor))
static void zano_library_init() {
#ifdef __ANDROID__
    setupAndroidLogging();
#endif
}
