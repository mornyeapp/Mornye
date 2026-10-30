package android.os;

/** Host stand-in that runs posted replies at once on the posting thread. */
public class Handler {

    public Handler(final Looper looper) {
    }

    public final boolean post(final Runnable r) {
        r.run();
        return true;
    }
}
