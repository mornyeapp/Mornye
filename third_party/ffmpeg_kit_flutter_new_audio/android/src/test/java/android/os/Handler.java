package android.os;

/** Host stand-in that queues posted work on its looper's thread. */
public class Handler {

    private final Looper looper;

    public Handler(final Looper looper) {
        this.looper = looper;
    }

    public final boolean post(final Runnable r) {
        looper.enqueue(r);
        return true;
    }
}
