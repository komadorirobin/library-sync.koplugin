# Snabbinstallation för Grimmory Sync Plugin

## 📋 Checklista

Följ dessa steg exakt:

I exemplen betyder `<koreader>` KOReaders användarmapp på din enhet, alltså mappen som innehåller `plugins/` och `crash.log`.

### 1. Förbered pluginet på din dator

✅ Kontrollera att du har mappen: `grimmory-sync.koplugin/`
✅ Mappen innehåller minst: `_meta.lua` och `main.lua`

### 2. Installera på din KOReader-enhet

#### Alternativ A: Via USB

1. **Anslut e-läsaren till datorn**
   - Använd USB-kabel
   - Välj "File Transfer" / "Överför filer" på e-läsaren

2. **Hitta plugins-mappen**
   - På datorn, navigera till e-läsarens lagring
   - Gå till: `koreader/plugins/`
   - Om `plugins` inte finns, skapa den

3. **Kopiera pluginet**
   - Kopiera HELA mappen `grimmory-sync.koplugin` till `koreader/plugins/`
   - Den fullständiga sökvägen ska bli:
     ```
     <koreader>/plugins/grimmory-sync.koplugin/_meta.lua
     <koreader>/plugins/grimmory-sync.koplugin/main.lua
     ```

4. **Koppla från USB**

#### Alternativ B: Via ADB (Avancerat)

```bash
# Aktivera USB-debugging på enheten först
adb devices
adb push grimmory-sync.koplugin <koreader>/plugins/
```

### 3. Starta om KOReader

1. **Stäng KOReader helt:**
   - Använd enhetens vanliga sätt att stänga appen helt
   - Om KOReader bara hamnar i bakgrunden, tvångsavsluta appen från enhetens apphantering

2. **Starta KOReader igen**

### 4. Verifiera installationen

1. Öppna KOReader
2. Tryck på menyikonen (☰) överst till vänster
3. Öppna **förstoringsglas-menyn** / **magnifying glass menu**
4. Du bör se **"Grimmory Sync"** i listan

Om du INTE ser "Grimmory Sync":
- ✅ Kontrollera att mappen verkligen heter `.koplugin` (inte `.koplugin.koplugin`)
- ✅ Kontrollera att filerna ligger direkt i mappen (inte i en undermapp)
- ✅ Starta om KOReader igen
- ✅ Kolla loggen (se nedan)

## 🔍 Kontrollera loggen

1. Använd en filhanterare på enheten
2. Gå till: `<koreader>/`
3. Öppna `crash.log` med en textläsare
4. Leta efter rader med `[GrimmorySync]` eller `grimmorysync`
5. Om du ser felmeddelanden, kopiera dem och dela med utvecklaren

## 🚀 Första gången

När pluginet syns i menyn:

1. **Gå till: Meny → Förstoringsglas → Grimmory Sync → Configure**
2. Ange Grimmory-serverns adress och port (t.ex. `http://192.168.1.100:6060`)
3. Ange användarnamn och lösenord för Grimmory
4. **Gå till: Meny → Förstoringsglas → Grimmory Sync → Sync missing books**
5. Vänta medan pluginet laddar ner dina böcker! 📚

## ℹ️ Hitta serverns IP-adress

Öppna nätverksinställningarna på datorn eller servern som kör Grimmory och leta efter IPv4-adressen på samma nätverk som läsplattan. Använd den adressen i `Server URL`, till exempel `http://192.168.1.100:6060`.

## 📝 Vanliga problem

| Problem | Lösning |
|---------|---------|
| Pluginet syns inte | Se checklistan ovan, kontrollera mappnamn |
| "Module not found" | Starta om KOReader, kontrollera filbehörigheter |
| "Cannot connect" | Kontrollera att Grimmory-servern och läsplattan är på samma nätverk |
| "401 Unauthorized" | Kontrollera användarnamn och lösenord |
| Inga böcker laddas ner | Kontrollera att den lokala biblioteksmappen finns och är skrivbar |

## 🆘 Fortfarande problem?

Skapa en issue med:
- KOReader-version (Hjälp → Om)
- Enhet och firmware-version
- Innehållet i `crash.log` (relevanta rader)
- Vad som händer när du försöker använda pluginet
