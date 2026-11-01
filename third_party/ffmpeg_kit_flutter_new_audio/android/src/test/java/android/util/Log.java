package android.util;

/**
 * Host stand-in for the Android class. Tests watch FFmpegKitConfig's static initializer
 * through its first log line, and may delay or fail the load there.
 */
public final class Log {

    public static final int VERBOSE = 2;
    public static final int DEBUG = 3;
    public static final int INFO = 4;
    public static final int WARN = 5;
    public static final int ERROR = 6;
    public static final int ASSERT = 7;

    public interface Listener {
        void onLog(int priority, String tag, String msg, Throwable tr);
    }

    public static volatile Listener listener;

    private Log() {
    }

    public static int v(final String tag, final String msg) {
        return println(VERBOSE, tag, msg, null);
    }

    public static int v(final String tag, final String msg, final Throwable tr) {
        return println(VERBOSE, tag, msg, tr);
    }

    public static int d(final String tag, final String msg) {
        return println(DEBUG, tag, msg, null);
    }

    public static int d(final String tag, final String msg, final Throwable tr) {
        return println(DEBUG, tag, msg, tr);
    }

    public static int i(final String tag, final String msg) {
        return println(INFO, tag, msg, null);
    }

    public static int i(final String tag, final String msg, final Throwable tr) {
        return println(INFO, tag, msg, tr);
    }

    public static int w(final String tag, final String msg) {
        return println(WARN, tag, msg, null);
    }

    public static int w(final String tag, final String msg, final Throwable tr) {
        return println(WARN, tag, msg, tr);
    }

    public static int w(final String tag, final Throwable tr) {
        return println(WARN, tag, null, tr);
    }

    public static int e(final String tag, final String msg) {
        return println(ERROR, tag, msg, null);
    }

    public static int e(final String tag, final String msg, final Throwable tr) {
        return println(ERROR, tag, msg, tr);
    }

    public static int wtf(final String tag, final String msg) {
        return println(ASSERT, tag, msg, null);
    }

    public static int wtf(final String tag, final String msg, final Throwable tr) {
        return println(ASSERT, tag, msg, tr);
    }

    public static int println(final int priority, final String tag, final String msg) {
        return println(priority, tag, msg, null);
    }

    public static boolean isLoggable(final String tag, final int level) {
        return true;
    }

    public static String getStackTraceString(final Throwable tr) {
        if (tr == null) {
            return "";
        }
        final java.io.StringWriter writer = new java.io.StringWriter();
        tr.printStackTrace(new java.io.PrintWriter(writer));
        return writer.toString();
    }

    private static int println(final int priority, final String tag, final String msg, final Throwable tr) {
        final Listener current = listener;
        if (current != null) {
            current.onLog(priority, tag, msg, tr);
        }
        return 0;
    }
}
