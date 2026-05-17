# Snabbinstallation för Grimmory Sync Plugin

## 📋 Checklista

Följ dessa steg exakt:

### 1. Förbered pluginet på din dator

✅ Kontrollera att du har mappen: `grimmory-sync.koplugin/`
✅ Mappen innehåller minst: `_meta.lua` och `main.lua`

### 2. Installera på Bigme B7 Pro

#### Alternativ A: Via USB

1. **Anslut e-läsaren till datorn**
   - Använd USB-kabel
   - Välj "File Transfer" / "Överför filer" på e-läsaren

2. **Hitta plugins-mappen**
   - På datorn, navigera till: `Internal Storage` eller `Bigme B7 Pro`
   - Gå till: `koreader/plugins/`
   - Om `plugins` inte finns, skapa den

3. **Kopiera pluginet**
   - Kopiera HELA mappen `grimmory-sync.koplugin` till `koreader/plugins/`
   - Den fullständiga sökvägen ska bli:
     ```
     /storage/emulated/0/koreader/plugins/grimmory-sync.koplugin/_meta.lua
     /storage/emulated/0/koreader/plugins/grimmory-sync.koplugin/main.lua
     ```

4. **Koppla från USB**

#### Alternativ B: Via ADB (Avancerat)

```bash
# Aktivera USB-debugging på Bigme först
adb devices
adb push grimmory-sync.koplugin /storage/emulated/0/koreader/plugins/
```

### 3. Starta om KOReader

1. **Stäng KOReader helt:**
   - Tryck på "Hem"-knappen (inte bara bakåt)
   - Svep upp från botten → välj KOReader → "Force Stop" / "Tvinga stopp"
   
2. **Starta KOReader igen**

### 4. Verifiera installationen

1. Öppna KOReader
2. Tryck på menyikonen (☰) överst till vänster
3. Scrolla ner till **"Verktyg"** / **"Tools"**
4. Du bör se **"Grimmory Sync"** i listan

Om du INTE ser "Grimmory Sync":
- ✅ Kontrollera att mappen verkligen heter `.koplugin` (inte `.koplugin.koplugin`)
- ✅ Kontrollera att filerna ligger direkt i mappen (inte i en undermapp)
- ✅ Starta om KOReader igen
- ✅ Kolla loggen (se nedan)

## 🔍 Kontrollera loggen

1. Använd en filhanterare på Bigme
2. Gå till: `/storage/emulated/0/koreader/`
3. Öppna `crash.log` med en textläsare
4. Leta efter rader med `[GrimmorySync]` eller `grimmorysync`
5. Om du ser felmeddelanden, kopiera dem och dela med utvecklaren

## 🚀 Första gången

När pluginet syns i menyn:

1. **Gå till: Meny → Verktyg → Grimmory Sync → Konfigurera server**
2. Ange din Macs IP-adress och port (t.ex. `http://192.168.1.100:6060`)
3. Ange användarnamn och lösenord för Grimmory
4. **Gå till: Meny → Verktyg → Grimmory Sync → Sync missing books**
5. Vänta medan pluginet laddar ner dina böcker! 📚

## ℹ️ Hitta din Macs IP-adress

Öppna Terminal på Mac:
```bash
ipconfig getifaddr en0    # För WiFi
ipconfig getifaddr en1    # Om en0 inte fungerar
```

Eller via Systeminställningar:
- Systeminställningar → Nätverk → WiFi → Detaljer → TCP/IP
- Kolla "IP-adress"

## 📝 Vanliga problem

| Problem | Lösning |
|---------|---------|
| Pluginet syns inte | Se checklistan ovan, kontrollera mappnamn |
| "Module not found" | Starta om KOReader, kontrollera filbehörigheter |
| "Cannot connect" | Kontrollera att Mac och Bigme är på samma WiFi |
| "401 Unauthorized" | Kontrollera användarnamn och lösenord |
| Inga böcker laddas ner | Kontrollera att `/storage/emulated/0/ePubs/` finns |

## 🆘 Fortfarande problem?

Skapa en issue med:
- KOReader-version (Hjälp → Om)
- Bigme B7 Pro firmware-version
- Innehållet i `crash.log` (relevanta rader)
- Vad som händer när du försöker använda pluginet
