package com.zarz.mornye;

import android.content.Intent;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.Binder;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsContract.Root;
import android.provider.DocumentsProvider;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

/** Uses Java only: a standalone test APK provider cannot use the app's Kotlin runtime. */
public final class LookupTestDocumentsProvider extends DocumentsProvider {
    private static final class Entry {
        final String id;
        final String parent;
        final String name;
        final String mime;
        final File file;

        Entry(String id, String parent, String name, String mime, File file) {
            this.id = id;
            this.parent = parent;
            this.name = name;
            this.mime = mime;
            this.file = file;
        }
    }

    private final Map<String, Entry> entries = new LinkedHashMap<>();
    private int sequence;
    private int childQueries;
    private int documentQueries;
    private int closedCursors;
    private final ArrayList<String> createdNames = new ArrayList<>();
    private final ArrayList<String> renamedNames = new ArrayList<>();
    private String projectionMode = "normal";
    private boolean failFinalRename;

    private File fixtureDir() {
        return new File(getContext().getCacheDir(), "lookup-provider");
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        switch (method) {
            case "lookup.reset":
                File[] previous = fixtureDir().listFiles();
                if (previous != null) for (File file : previous) file.delete();
                fixtureDir().mkdirs();
                entries.clear();
                sequence = 0;
                projectionMode = extras.getString("mode", "normal");
                failFinalRename = extras.getBoolean("failFinalRename");
                add("root", null, "Root", projectionMode.equals("root-empty-mime") ? "" : Document.MIME_TYPE_DIR);
                for (int i = 0; i < extras.getInt("count"); i++) {
                    add("child:" + i, "root", "Track " + i + ".flac", "audio/flac");
                }
                add("nested:音楽/opaque", "root", "音楽 🎵", Document.MIME_TYPE_DIR);
                add("song:opaque/%", "nested:音楽/opaque", "歌 🎵.flac", "audio/flac");
                if (projectionMode.equals("no-path")) {
                    add("root/album", "root", "Legacy", Document.MIME_TYPE_DIR);
                    add("root/album/song", "root/album", "Legacy.flac", "audio/flac");
                }
                if (extras.getBoolean("mimeCases")) {
                    add("mime:null", "root", "Null.flac", null);
                    add("mime:empty", "root", "Empty.flac", "");
                    add("mime:generic", "root", "Generic.flac", "application/octet-stream");
                }
                Entry original = add("original", "root", "Song.flac", "audio/flac");
                try (FileOutputStream output = new FileOutputStream(original.file)) {
                    output.write(new byte[] {'o', 'r', 'i', 'g', 'i', 'n', 'a', 'l'});
                } catch (IOException e) {
                    throw new IllegalStateException(e);
                }
                // Simulate the narrow tree grant normally issued by the picker.
                long identity = Binder.clearCallingIdentity();
                try {
                    getContext().grantUriPermission(
                        extras.getString("targetPackage"),
                        DocumentsContract.buildTreeDocumentUri("com.mornye.test.documents.lookup", "root"),
                        Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION |
                            Intent.FLAG_GRANT_PREFIX_URI_PERMISSION |
                            (extras.getBoolean("persistable") ? Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION : 0)
                    );
                } finally {
                    Binder.restoreCallingIdentity(identity);
                }
                resetCounters();
                return new Bundle();
            case "lookup.clearCounters":
                resetCounters();
                return new Bundle();
            case "lookup.stats":
                Bundle stats = new Bundle();
                stats.putInt("children", childQueries);
                stats.putInt("documents", documentQueries);
                stats.putInt("closed", closedCursors);
                stats.putStringArrayList("createdNames", new ArrayList<>(createdNames));
                stats.putStringArrayList("renamedNames", new ArrayList<>(renamedNames));
                return stats;
            default:
                return super.call(method, arg, extras);
        }
    }

    private void resetCounters() {
        childQueries = 0;
        documentQueries = 0;
        closedCursors = 0;
        createdNames.clear();
        renamedNames.clear();
    }

    private Entry add(String id, String parent, String name, String mime) {
        Entry entry = new Entry(id, parent, name, mime, new File(fixtureDir(), "data-" + sequence++));
        entries.put(id, entry);
        return entry;
    }

    private MatrixCursor cursor(String[] columns) {
        return new MatrixCursor(columns) {
            @Override
            public void close() {
                if (!isClosed()) closedCursors++;
                super.close();
            }
        };
    }

    private void addEntry(MatrixCursor cursor, Entry entry) {
        String[] columns = cursor.getColumnNames();
        Object[] row = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            switch (columns[i]) {
                case Document.COLUMN_DOCUMENT_ID: row[i] = entry.id; break;
                case Document.COLUMN_DISPLAY_NAME: row[i] = entry.name; break;
                case Document.COLUMN_MIME_TYPE: row[i] = entry.mime; break;
                case Document.COLUMN_SIZE: row[i] = entry.file.length(); break;
                case Document.COLUMN_LAST_MODIFIED: row[i] = 1234L; break;
                case Document.COLUMN_FLAGS:
                    row[i] = Document.FLAG_SUPPORTS_WRITE | Document.FLAG_SUPPORTS_DELETE |
                        Document.FLAG_SUPPORTS_RENAME | Document.FLAG_DIR_SUPPORTS_CREATE;
                    break;
                default: break;
            }
        }
        cursor.addRow(row);
    }

    @Override
    public Cursor queryRoots(String[] projection) {
        String[] columns = projection != null ? projection :
            new String[] {Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE};
        MatrixCursor cursor = new MatrixCursor(columns);
        Object[] row = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            if (Root.COLUMN_ROOT_ID.equals(columns[i]) || Root.COLUMN_DOCUMENT_ID.equals(columns[i])) row[i] = "root";
            else if (Root.COLUMN_TITLE.equals(columns[i])) row[i] = "Lookup fixture";
        }
        cursor.addRow(row);
        return cursor;
    }

    @Override
    public Cursor queryDocument(String documentId, String[] projection) throws FileNotFoundException {
        documentQueries++;
        Entry entry = entries.get(documentId);
        if (entry == null) throw new FileNotFoundException(documentId);
        MatrixCursor cursor = cursor(projection != null ? projection : defaultColumns());
        if (documentId.equals("root") &&
            (projectionMode.equals("root-metadata-empty") || projectionMode.equals("root-unconfirmed"))) {
            return cursor;
        }
        addEntry(cursor, entry);
        return cursor;
    }

    @Override
    public Cursor queryChildDocuments(String parentId, String[] projection, String sortOrder) {
        childQueries++;
        if (projectionMode.equals("all-null")) return null;
        boolean projected = projection != null && Arrays.asList(projection).contains(Document.COLUMN_DISPLAY_NAME);
        if (projected && projectionMode.equals("throw")) throw new UnsupportedOperationException("projection");
        if (projected && projectionMode.equals("null")) return null;
        String[] columns = projected && projectionMode.equals("missing") ?
            new String[] {Document.COLUMN_DOCUMENT_ID} : projection != null ? projection : defaultColumns();
        MatrixCursor cursor = cursor(columns);
        if (projectionMode.equals("always-loading") ||
            (projectionMode.equals("loading") && childQueries <= 2)) {
            Bundle extras = new Bundle();
            extras.putBoolean(DocumentsContract.EXTRA_LOADING, true);
            cursor.setExtras(extras);
            return cursor;
        }
        if (parentId.equals("root") &&
            (projectionMode.equals("root-unconfirmed") || projectionMode.equals("empty"))) {
            return cursor;
        }
        for (Entry entry : entries.values()) if (parentId.equals(entry.parent)) addEntry(cursor, entry);
        return cursor;
    }

    @Override
    public DocumentsContract.Path findDocumentPath(String parentId, String childId) throws FileNotFoundException {
        if (projectionMode.equals("no-path")) throw new UnsupportedOperationException("Path unavailable");
        ArrayList<String> path = new ArrayList<>();
        Entry entry = entries.get(childId);
        while (entry != null) {
            path.add(0, entry.id);
            if (entry.id.equals(parentId)) return new DocumentsContract.Path(null, path);
            entry = entries.get(entry.parent);
        }
        throw new FileNotFoundException(childId);
    }

    @Override
    public boolean isChildDocument(String parentId, String documentId) {
        Entry entry = entries.get(documentId);
        while (entry != null && entry.parent != null) {
            if (parentId.equals(entry.parent)) return true;
            entry = entries.get(entry.parent);
        }
        return false;
    }

    @Override
    public String createDocument(String parentId, String mimeType, String displayName) {
        createdNames.add(displayName);
        String id = "created:" + sequence++;
        add(id, parentId, displayName, mimeType);
        return id;
    }

    @Override
    public String renameDocument(String documentId, String displayName) throws FileNotFoundException {
        Entry entry = entries.get(documentId);
        if (entry == null) throw new FileNotFoundException(documentId);
        if (failFinalRename && (entry.name.endsWith(".partial") || entry.name.contains(".partial."))
                && displayName.equals("Song.flac")) {
            throw new FileNotFoundException("Injected publish rename failure");
        }
        String newId = "renamed:" + sequence++;
        renamedNames.add(displayName);
        entries.remove(documentId);
        entries.put(newId, new Entry(newId, entry.parent, displayName, entry.mime, entry.file));
        return newId;
    }

    @Override
    public void deleteDocument(String documentId) {
        Entry entry = entries.remove(documentId);
        if (entry != null) entry.file.delete();
    }

    @Override
    public ParcelFileDescriptor openDocument(String documentId, String mode, CancellationSignal signal) throws FileNotFoundException {
        Entry entry = entries.get(documentId);
        if (entry == null) throw new FileNotFoundException(documentId);
        return ParcelFileDescriptor.open(entry.file, ParcelFileDescriptor.parseMode(mode));
    }

    private String[] defaultColumns() {
        return new String[] {Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE};
    }
}
