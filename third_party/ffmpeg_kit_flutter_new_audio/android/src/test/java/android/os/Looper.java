package android.os;

/** Host stand-in for the main looper the plugin's result handler posts to. */
public final class Looper {

    private static final Looper MAIN = new Looper();

    private Looper() {
    }

    public static Looper getMainLooper() {
        return MAIN;
    }
}
