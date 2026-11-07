# FirewallaDock

App macOS per il Dock che mostra lo stato della tua rete Firewalla leggendo i dati tramite la [Firewalla MSP API v2](https://docs.firewalla.net).

> Progetto indipendente, non affiliato né approvato da Firewalla Inc.

## Funzionalità

- **Badge sull'icona del Dock** con il numero di allarmi attivi (opzionale: solo allarmi di sicurezza); `!` se la connessione fallisce
- **Menu del Dock** (clic destro): stato dei box, allarmi attivi, dispositivi online, ultimi allarmi, aggiornamento manuale
- **Panoramica**: statistiche, elenco box, grafici giornalieri di allarmi e flussi bloccati, allarmi per tipo
- **Allarmi**: ricerca, filtro per tipo, archiviazione (richiede token *Full Access*)
- **Dispositivi**: tabella ordinabile con IP, MAC, produttore, rete, traffico
- **Flussi**: tutti o solo bloccati, con [query di ricerca](https://docs.firewalla.net/api-reference/search/) avanzate
- Aggiornamento automatico (1–60 min) e notifiche per i nuovi allarmi
- Token API salvato nel Portachiavi; app in sandbox con solo accesso di rete in uscita

## Requisiti

- macOS 14 o successivo
- Xcode 16 o successivo
- Un account [Firewalla MSP](https://firewalla.net) con un token API

## Compilazione

```bash
git clone https://github.com/massan71/FirewallaDock.git
cd FirewallaDock
open FirewallaDock.xcodeproj
```

Poi ⌘R in Xcode. Da riga di comando:

```bash
xcodebuild -project FirewallaDock.xcodeproj -scheme FirewallaDock -configuration Release -derivedDataPath build/DerivedData build
cp -R build/DerivedData/Build/Products/Release/FirewallaDock.app /Applications/
```

L'app è firmata ad-hoc ("Sign to Run Locally"); per distribuirla ad altri imposta il tuo Team di sviluppo in Xcode.

## Configurazione

1. In Firewalla MSP: **Settings → MSP API → Create New Token** (*Read Only* basta per la lettura).
2. Apri l'app → **Impostazioni** (⌘,).
3. Inserisci l'URL base (`https://<tuodominio>.firewalla.net` oppure `https://firewalla.net/api`) e il token, poi **Salva e verifica**.

## Struttura

| File | Contenuto |
|---|---|
| `FirewallaDock/FirewallaAPI.swift` | Client HTTP per gli endpoint `/v2/boxes`, `/v2/devices`, `/v2/alarms`, `/v2/flows`, `/v2/trends/*` |
| `FirewallaDock/Models.swift` | Modelli con decodifica tollerante |
| `FirewallaDock/Store.swift` | Stato, aggiornamento periodico, badge del Dock, notifiche |
| `FirewallaDock/App.swift` | Entry point e menu del Dock |
| `FirewallaDock/Views.swift` | Interfaccia SwiftUI |
| `FirewallaDock/Keychain.swift` | Salvataggio del token nel Portachiavi |

## Licenza

Distribuito con licenza [MIT](LICENSE).
