package android.os;

import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * Host stand-in: the main looper is one thread named "main" that runs posted work in order.
 * Work that throws ends the thread, as an uncaught exception on the main thread ends the app.
 */
public final class Looper {

    private static final Looper MAIN = new Looper("main");

    private final BlockingQueue<Runnable> queue = new LinkedBlockingQueue<>();
    private final Thread thread;

    private Looper(final String name) {
        thread = new Thread(this::loop, name);
        thread.setDaemon(true);
        thread.start();
    }

    public static Looper getMainLooper() {
        return MAIN;
    }

    public Thread getThread() {
        return thread;
    }

    public boolean isCurrentThread() {
        return Thread.currentThread() == thread;
    }

    void enqueue(final Runnable r) {
        queue.add(r);
    }

    private void loop() {
        while (true) {
            final Runnable next;
            try {
                next = queue.take();
            } catch (final InterruptedException e) {
                return;
            }
            next.run();
        }
    }
}
