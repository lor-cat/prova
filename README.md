# Guida all'Analisi Statica del Codice .NET

Questa guida descrive come eseguire l'analisi statica del codice, dividere i report SARIF e visualizzarne i risultati.

---

## Indice

1. [Prerequisiti](#1-prerequisiti)
2. [File di configurazione](#2-file-di-configurazione)
3. [Esecuzione dell'analizzatore](#3-esecuzione-dellanalizzatore)
4. [Divisione dei file SARIF](#4-divisione-dei-file-sarif)
5. [Visualizzazione dei risultati](#5-visualizzazione-dei-risultati)
6. [Riferimenti alle regole di analisi Microsoft](#6-riferimenti-alle-regole-di-analisi-microsoft)

---

## 1. Prerequisiti

### Estensione SARIF Viewer per Visual Studio

Per visualizzare i file `.sarif` direttamente in Visual Studio è necessario installare l'estensione **Microsoft SARIF Viewer 2022**.

- **Dal Marketplace**: [WDGIS.MicrosoftSarifViewer2022](https://marketplace.visualstudio.com/items?itemName=WDGIS.MicrosoftSarifViewer2022)
- **Da Visual Studio**: `Estensioni` → `Gestisci estensioni` → cercare *SARIF Viewer*

> **Nota**: Visual Studio può andare in crash se si tenta di aprire file SARIF molto grandi (> 5 MB). In tal caso usare prima lo splitter (sezione 4) o il visualizzatore web (sezione 5).

### Requisiti di sistema

- PowerShell 5.1 o superiore
- .NET SDK compatibile con la soluzione
- Visual Studio 2022 (per la visualizzazione in-IDE)

---

## 2. File di configurazione

### `Directory.Build.props`

File MSBuild applicato automaticamente a **tutti i progetti** della soluzione. Abilita e configura gli analizzatori .NET:

| Proprietà | Valore | Descrizione |
|---|---|---|
| `EnableNETAnalyzers` | `true` | Attiva gli analizzatori Roslyn integrati |
| `RunAnalyzers` | `true` | Esegue gli analizzatori durante la build |
| `EnforceCodeStyleInBuild` | `true` | Applica le regole di stile anche in build CI |
| `AnalysisLevel` | `latest` | Usa le regole dell'ultima versione SDK |
| `AnalysisMode` | `AllEnabledByDefault` | Abilita tutte le regole per default |
| `TreatWarningsAsErrors` | `false` | I warning non bloccano la build (solo gli `error` la bloccano) |

### `.editorconfig.analysis`

File di configurazione delle severità delle regole, copiato nella directory di lavoro prima della build. Implementa un **sistema a tre livelli**:

| Livello | Utilizzo | Effetto sulla build |
|---|---|---|
| **`error`** | Solo vulnerabilità critiche (OWASP Top 10, violazioni MDR Annex I) | ❌ **Blocca la build** |
| **`warning`** | Affidabilità, nullability, resource leaks | ⚠️ Segnalato, non bloccante |
| **`suggestion`** | Stile, ottimizzazioni minori | 💡 Solo informativo |

Questo modello garantisce la **compilazione incrementale** dei progetti dipendenti anche in presenza di warning, bloccando solo le vulnerabilità di sicurezza critiche. La configurazione è allineata ai requisiti **MDR 2017/745** (Annex I, Requisito 17) per dispositivi medici.

---

## 3. Esecuzione dell'analizzatore

Lo script `start-analyze-dotnet.ps1` esegue la build della soluzione con analisi statica e aggrega i risultati in un unico file SARIF.

### Utilizzo

```powershell
.\start-analyze-dotnet.ps1 [-RootDir <percorso>] [-OutputDir <cartella>] [-SolutionPath <file.sln>] [-SarifFileName <nome.sarif>] [-FailOnError]
```

### Parametri

| Parametro | Default | Descrizione |
|---|---|---|
| `-RootDir` | `.` | Directory radice della soluzione |
| `-OutputDir` | `AnalysisReports` | Cartella di output per i report |
| `-SolutionPath` | `Tmed.sln` | Percorso del file `.sln` |
| `-SarifFileName` | `complete.sarif` | Nome del file SARIF aggregato |
| `-FailOnError` | *(switch)* | Se specificato, restituisce exit code 1 se ci sono errori |

### Esempi

```powershell
# Analisi con impostazioni di default
.\start-analyze-dotnet.ps1

# Analisi con FailOnError (utile in pipeline CI)
.\start-analyze-dotnet.ps1 -FailOnError

# Analisi su una soluzione specifica
.\start-analyze-dotnet.ps1 -SolutionPath "MySolution.sln" -OutputDir "Reports"
```

### Output

Al termine dell'analisi, nella cartella `AnalysisReports/` saranno presenti:
- `complete.sarif` — file SARIF aggregato con tutti i risultati
- `per-project/` — file SARIF per singolo progetto

---

## 4. Divisione dei file SARIF

Se il file SARIF generato è troppo grande per essere aperto in Visual Studio, usare lo script `_SarifSplitter.ps1` per dividerlo in chunk più piccoli.

### Utilizzo

```powershell
cd AnalysisReports\per-project
.\_SarifSplitter.ps1 [-InputFolder <percorso>] [-ChunkSizeMB <dimensione>] [-OutputFolder <nome>] [-Force]
```

### Parametri

| Parametro | Default | Descrizione |
|---|---|---|
| `-InputFolder` | `.` | Cartella contenente i file `.sarif` |
| `-ChunkSizeMB` | `5` | Dimensione massima di ogni chunk (0.1–100 MB) |
| `-OutputFolder` | `ChunkedSarif` | Sottocartella di output |
| `-Force` | *(switch)* | Sovrascrive l'output esistente |

### Workflow completo

```powershell
# 1. Esegui l'analisi
.\start-analyze-dotnet.ps1

# 2. Dividi i file SARIF in chunk da 5 MB
cd AnalysisReports\per-project
.\_SarifSplitter.ps1 -ChunkSizeMB 5 -Force
```

I file divisi vengono salvati in `ChunkedSarif\` con nomi `nomefile-chunk1.sarif`, `nomefile-chunk2.sarif`, ecc. Ogni chunk è un file SARIF valido e indipendente.

---

## 5. Visualizzazione dei risultati

### In Visual Studio (file piccoli o chunk)

Dopo aver installato l'estensione SARIF Viewer, aprire il file `.sarif` da Esplora Soluzioni o tramite `File` → `Apri`. I risultati appaiono nel pannello **Error List**.

### Visualizzatore web (consigliato per file grandi)

Per file SARIF di grandi dimensioni che potrebbero far crashare Visual Studio:

🔗 **[https://microsoft.github.io/sarif-web-component/](https://microsoft.github.io/sarif-web-component/)**

Caricare il file `.sarif` direttamente nel browser — nessuna installazione richiesta.

### Validatore SARIF

Per verificare la conformità allo schema SARIF 2.1.0:

🔗 **[https://sarifweb.azurewebsites.net/Validation](https://sarifweb.azurewebsites.net/Validation)**

Utile per diagnosticare problemi di parsing o incompatibilità con altri strumenti.

---

## 6. Riferimenti alle regole di analisi Microsoft

La documentazione completa di tutte le regole di qualità del codice .NET (CA*) è disponibile nel portale Microsoft Learn:

🔗 **Indice generale delle regole**: [https://learn.microsoft.com/it-it/dotnet/fundamentals/code-analysis/quality-rules/](https://learn.microsoft.com/it-it/dotnet/fundamentals/code-analysis/quality-rules/)

🔗 **Esempio — CA2100** (SQL injection): [https://learn.microsoft.com/it-it/dotnet/fundamentals/code-analysis/quality-rules/ca2100](https://learn.microsoft.com/it-it/dotnet/fundamentals/code-analysis/quality-rules/ca2100)

> Per accedere a qualsiasi altra regola, modificare il codice nell'URL (es. `ca1001`, `ca2213`, ecc.).

Le regole sono organizzate per categoria:

| Prefisso | Categoria |
|---|---|
| CA1xxx | Design, Naming, Performance, Reliability, Globalization |
| CA2xxx | Security, Usage |
| CA3xxx | Security (data flow) |
| IDE0xxx | Code style |