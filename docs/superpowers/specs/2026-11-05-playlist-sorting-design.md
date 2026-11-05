# Design Doc: Ordinamento Temporaneo Playlist (Stile Spotify)

## Contesto & Obiettivo
In Mornye, le playlist create dall'utente (gestite in `LibraryTracksFolderScreen`) memorizzano per ciascun brano la data di aggiunta (`addedAt` in `CollectionTrackEntry`). Tuttavia, l'utente può attualmente riordinare i brani solo manualmente tramite trascinamento (`Icons.swap_vert`).
L'obiettivo è consentire all'utente di ordinare temporaneamente la visualizzazione della playlist secondo vari criteri (in stile Spotify), senza sovrascrivere l'ordine manuale salvato, garantendo un'esperienza coerente sia su dispositivi mobili/touch sia su desktop.

## Criteri di Ordinamento
Verrà introdotto un enum `PlaylistSortOption`:
- **Ordine personalizzato** (`custom` / predefinito): l'ordine manuale memorizzato nella playlist.
- **Data di aggiunta** (`dateAddedDesc` e `dateAddedAsc`): brani aggiunti più di recente prima (predefinito per data) o meno di recente prima.
- **Titolo** (`titleAsc` e `titleDesc`): ordine alfabetico A-Z / Z-A per nome brano.
- **Artista** (`artistAsc` e `artistDesc`): ordine alfabetico A-Z / Z-A per nome artista.
- **Album** (`albumAsc` e `albumDesc`): ordine alfabetico A-Z / Z-A per nome album.
- **Durata** (`durationAsc` e `durationDesc`): brani più brevi prima o più lunghi prima.

## Approcci Considerati
1. **Approccio 1 (Scelto dall'utente - Desktop & Mobile Spotify-style)**:
   - Pulsante "Ordina" dedicato nella testata / barra delle azioni della schermata playlist (`LibraryTracksFolderScreen` e `PlaylistScreen`).
   - Su mobile/touch: apre un bottom sheet modale chiaro con le opzioni di ordinamento e indicatore della direzione (ascendente/discendente).
   - Su desktop: menu contestuale/popup a comparsa e aggiunta della colonna opzionale "Data di aggiunta" (`TrackTableColumn.dateAdded`) su `TrackListTable` / `SliverTrackTable`, con possibilità di cliccare sulle intestazioni delle colonne per invertire l'ordinamento.
   - La riproduzione (tap su brano, Riproduci tutto, Shuffle) segue la sequenza attualmente ordinata a schermo.
2. **Approccio 2 (Solo menu rapido senza colonna desktop)**:
   - Solo pulsante di ordinamento nella testata, senza arricchire la tabella desktop. Scartato perché incompleto rispetto all'esperienza desktop attesa da Spotify.

## Dettagli Architetturali & Modifiche al Codice

### 1. Modello di Ordinamento (`lib/models/playlist_sort.dart`)
- Definizione dell'enum o classe `PlaylistSortMode` con metodi di utilità per:
  - Comparatori Dart per ordinare `List<CollectionTrackEntry>` o `List<Track>`.
  - Etichette localizzate o leggibili (con supporto l10n per le lingue principali / fallback).

### 2. Schermata Playlist Libreria (`lib/screens/library_tracks_folder_screen.dart`)
- Aggiunta dello stato locale `PlaylistSortMode _sortMode = PlaylistSortMode.custom;`.
- Calcolo della lista ordinata `_sortedEntries` mantenendo intatta la lista originale `entries`.
- Aggiunta del pulsante "Ordina" nell'appBar / header (`appBarActions` accanto al pulsante di riordinamento manuale).
- Selezionando un ordinamento diverso da `custom`:
  - L'icona evidenzia lo stato attivo.
  - La modalità di modifica manuale dell'ordine (`_editOrder`) avvisa o reimposta l'ordine personalizzato se necessario.
  - La riproduzione dei brani rispetta la lista ordinata a schermo.

### 3. Integrazione Desktop (`lib/widgets/desktop/track_table.dart` & `track_list_table.dart`)
- Aggiunta del tipo di colonna `TrackTableColumn.dateAdded` a `TrackTableColumn`.
- Formattazione relativa della data (es. "Oggi", "3 giorni fa", o formato data compatto).
- Gestione del click sull'intestazione per passare da crescente a decrescente e ripristino ordine manuale.

### 4. Supporto a `PlaylistScreen` (Playlist esterne/importate)
- Integrazione dello stesso menu di ordinamento su `PlaylistScreen`, ordinando per titolo, artista, album, durata o data di rilascio (`releaseDate` come fallback se `addedAt` non è presente).

## Non-Obiettivi
- Non altera in modo distruttivo l'ordine fisico salvato nel database/file di Mornye, salvo se l'utente sceglie esplicitamente la modalità manuale.
- Non altera le logiche di sincronizzazione di rete (Mornye Link), che verranno affrontate nella seconda fase dedicata.
