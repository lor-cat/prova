# SARIF Splitter

Script PowerShell per dividere file SARIF di grandi dimensioni in chunk più piccoli.

## Descrizione

`_SarifSplitter.ps1` è uno script che processa tutti i file SARIF presenti in una cartella e li divide in chunk di dimensione configurabile (in MB). I file divisi vengono salvati in una sottocartella `ChunkedSarif\` mantenendo l'integrità del formato SARIF 2.1.0.

Questo è utile quando i file SARIF generati dalle analisi statiche sono troppo grandi per essere caricati o visualizzati in alcuni strumenti.

## Utilizzo

### Sintassi di Base

```powershell
.\SarifSplitter.ps1 [-InputFolder <percorso>] [-ChunkSizeMB <dimensione>] [-OutputFolder <nome>] [-Force]
```

### Parametri

- **InputFolder** (opzionale)
  - Percorso della cartella contenente i file SARIF da processare
  - Default: cartella corrente (`.`)
  - Esempio: `-InputFolder "C:\Reports"`

- **ChunkSizeMB** (opzionale)
  - Dimensione massima di ogni chunk in megabyte
  - Range: 0.1 - 100 MB
  - Default: 5 MB
  - Esempio: `-ChunkSizeMB 10`

- **OutputFolder** (opzionale)
  - Nome della cartella di output relativa a InputFolder
  - Default: `ChunkedSarif`
  - Esempio: `-OutputFolder "Divided"`

- **Force** (opzionale)
  - Se specificato, sovrascrive la cartella di output esistente
  - Esempio: `-Force`

### Esempi

#### Esempio 1: Utilizzo Base
Divide tutti i file SARIF nella cartella corrente in chunk da 5 MB:

```powershell
.\SarifSplitter.ps1
```

#### Esempio 2: Specifica Cartella e Dimensione
Divide tutti i file SARIF in una cartella specifica con chunk da 10 MB:

```powershell
.\SarifSplitter.ps1 -InputFolder "C:\AnalysisReports" -ChunkSizeMB 10
```

#### Esempio 3: Sovrascrittura Output
Divide i file SARIF in chunk da 3 MB, sovrascrivendo l'output esistente:

```powershell
.\SarifSplitter.ps1 -ChunkSizeMB 3 -Force
```

#### Esempio 4: Cartella di Output Personalizzata
Usa una cartella di output personalizzata:

```powershell
.\SarifSplitter.ps1 -OutputFolder "SarifDivisi" -ChunkSizeMB 8
```

## Funzionamento

Lo script esegue le seguenti operazioni:

1. **Scansione**: Trova tutti i file `.sarif` nella cartella di input
2. **Analisi**: Per ogni file SARIF:
   - Verifica che sia un SARIF valido con runs e risultati
   - Calcola la dimensione del file
   - Se il file è sotto il limite, lo copia direttamente
   - Se il file supera il limite, lo divide in chunk
3. **Divisione**: I risultati SARIF vengono divisi mantenendo:
   - La struttura del documento SARIF 2.1.0
   - Le informazioni sul tool analyzer
   - Le proprietà originalUriBaseIds
   - Tutte le proprietà del run
4. **Output**: Salva i chunk nella cartella `ChunkedSarif\` con nomi:
   - File sotto il limite: `nomefile.sarif`
   - File divisi: `nomefile-chunk1.sarif`, `nomefile-chunk2.sarif`, etc.

## Struttura Output

```
InputFolder/
├── file1.sarif              (file originale)
├── file2.sarif              (file originale)
└── ChunkedSarif/            (cartella output)
    ├── file1.sarif          (copiato se < limite)
    ├── file2-chunk1.sarif   (chunk 1 di file2)
    ├── file2-chunk2.sarif   (chunk 2 di file2)
    └── file2-chunk3.sarif   (chunk 3 di file2)
```

## Log e Messaggi

Lo script produce output colorato per facilitare il monitoraggio:

- **Verde**: Operazioni completate con successo
- **Giallo**: Avvisi (file saltati, output esistente)
- **Rosso**: Errori critici
- **Bianco**: Informazioni generali

### Esempio di Output

```
==========================================
SARIF Splitter - Divisione file SARIF
==========================================

Cartella input: /path/to/reports
Dimensione chunk: 5 MB
Cartella di output creata: /path/to/reports/ChunkedSarif

Trovati 2 file SARIF da processare

Processando: /path/to/reports/large-report.sarif
  Trovati 1000 risultati
  Dimensione originale: 12.5 MB
  Chunk 1: 4.8 MB (380 risultati)
  Chunk 2: 4.9 MB (385 risultati)
  Chunk 3: 2.8 MB (235 risultati)
  Completato: 3 chunk creati

Processando: /path/to/reports/small-report.sarif
  Trovati 50 risultati
  Dimensione originale: 0.8 MB
  File già sotto il limite. Copiato senza modifiche.

==========================================
Completato!
File processati: 2 / 2
Chunk totali creati: 4
Output salvato in: /path/to/reports/ChunkedSarif
==========================================
```

## Requisiti

- PowerShell 5.1 o superiore
- File SARIF conformi allo schema 2.1.0
- Permessi di lettura sulla cartella di input
- Permessi di scrittura per creare la cartella di output

## Gestione Errori

Lo script gestisce i seguenti scenari:

- **File non SARIF**: Saltati con avviso
- **File SARIF senza risultati**: Saltati con avviso
- **Cartella output esistente**: Richiede `-Force` per sovrascrivere
- **Errori di lettura/scrittura**: Registrati con messaggio di errore
- **Cartella input non esistente**: Errore critico con exit code 1

## Note

- I file originali **non vengono modificati**
- Lo script mantiene la conformità allo schema SARIF 2.1.0
- Ogni chunk è un file SARIF valido e può essere aperto indipendentemente
- I chunk mantengono le informazioni di originalUriBaseIds per la corretta visualizzazione dei percorsi

## Integrazione con start-analyze-dotnet.ps1

Questo script può essere utilizzato dopo l'esecuzione di `start-analyze-dotnet.ps1` per dividere i file SARIF generati nella cartella `AnalysisReports/per-project`.

Esempio di workflow:

```powershell
# 1. Esegui l'analisi
.\start-analyze-dotnet.ps1

# 2. Dividi i file SARIF se necessario
cd AnalysisReports\per-project
.\SarifSplitter.ps1 -ChunkSizeMB 5 -Force
```

## Autore

Generato per TMED Analysis Reports

## Versione

1.0.0
