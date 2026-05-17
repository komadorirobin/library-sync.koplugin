# 🐛 Felsökningsguide - Plugin syns inte

## Steg 1: Verifiera filstrukturen

Kontrollera att du har EXAKT denna struktur på din e-läsare:

```
/koreader/
  └── plugins/
      └── booklore-sync.koplugin/
          ├── _meta.lua
          ├── main.lua
          ├── README.md
          ├── test-minimal.lua  (ny fil)
          └── DEBUG.md (denna fil)
```

**VIKTIGT:** Mappen MÅSTE heta `booklore-sync.koplugin` (med punkten före koplugin)

## Steg 2: Testa med minimal version

1. **Byt namn på filer:**
   - Byt namn på `main.lua` till `main.lua.backup`
   - Byt namn på `test-minimal.lua` till `main.lua`

2. **Starta om KOReader:**
   - Stäng KOReader HELT
   - Öppna KOReader igen

3. **Kolla om "Booklore Sync (TEST)" syns i menyn**
   - Om JA → Pluginet fungerar, problemet är i huvudkoden
   - Om NEJ → Gå till Steg 3

## Steg 3: Kontrollera var KOReader letar

KOReader kan leta på olika platser beroende på installation:

### Alternativ A: Intern lagring
```
/storage/emulated/0/koreader/plugins/booklore-sync.koplugin/
```

### Alternativ B: Appens datamapp
```
/data/data/org.koreader.launcher/files/koreader/plugins/booklore-sync.koplugin/
```

### Alternativ C: SD-kort (om du har)
```
/storage/sdcard1/koreader/plugins/booklore-sync.koplugin/
```

## Steg 4: Hitta rätt plats via KOReader

1. Öppna KOReader
2. Gå till: Verktyg → Mer verktyg → Terminal emulator (om den finns)
3. Eller installera ett existerande plugin för att se var plugins ligger

**Enklare metod:**
1. Använd en filhanterare-app på Bigme
2. Sök efter "koreader" 
3. Hitta `plugins`-mappen
4. Lägg pluginet där

## Steg 5: Kontrollera KOReader-version

Vissa äldre versioner av KOReader kanske inte stöder alla funktioner.

1. Öppna KOReader
2. Gå till: Hjälp → Om
3. Kolla versionen

**Minsta rekommenderade version:** v2021.04 eller senare

## Steg 6: Manuell syntax-kontroll

Om du har tillgång till en terminal på Bigme:

```bash
# Testa Lua-syntax
cd /koreader/plugins/booklore-sync.koplugin/
luac -p main.lua

# Om fel, byt till minimal version:
mv main.lua main.lua.broken
mv test-minimal.lua main.lua
```

## Steg 7: Kolla KOReader-loggen

1. Stäng KOReader
2. Med filhanterare, gå till `/koreader/` 
3. Öppna `crash.log` med textläsare
4. Leta efter:
   - `bookloresync`
   - `booklore-sync.koplugin`
   - `error` eller `failed`

**Vanliga fel du kan se:**

### "module 'datastorage' not found"
→ KOReader-version är för gammal

### "unexpected symbol near"
→ Syntax-fel i koden, använd minimal version

### Inget meddelande alls
→ KOReader läser inte från den mappen du kopierat till

## Steg 8: Prova alternativ plats

Om ingenting fungerar, prova denna metod:

1. **Hitta ett plugin som FUNGERAR:**
   - Gå till Verktyg i KOReader
   - Se vilket plugin som helst som redan finns (t.ex. "Statistics", "Calibre", etc.)

2. **Använd en filhanterare:**
   - Sök efter det plugin-namnet på enheten
   - Hitta var det ligger (t.ex. `.../statistics.koplugin/`)
   - Lägg ditt plugin i SAMMA mapp

3. **Exempel:**
   - Om du hittar: `/data/media/0/koreader/plugins/statistics.koplugin/`
   - Kopiera din mapp till: `/data/media/0/koreader/plugins/booklore-sync.koplugin/`

## Steg 9: ADB-metoden (Avancerat)

Om du har ADB aktiverat:

```bash
# Hitta rätt plats
adb shell find /sdcard -name "*.koplugin" -type d 2>/dev/null
adb shell find /storage -name "*.koplugin" -type d 2>/dev/null

# Kopiera dit
adb push booklore-sync.koplugin /RÄTT/PLATS/plugins/

# Starta om KOReader
adb shell am force-stop org.koreader.launcher
adb shell am start org.koreader.launcher
```

## Steg 10: Sista utvägen

Om INGENTING fungerar, testa:

1. Avinstallera KOReader
2. Installera om KOReader
3. Öppna KOReader en gång (så att mappar skapas)
4. Kopiera pluginet till plugins-mappen
5. Starta om

## 📋 Checklista

Bocka av när du gjort:

- [ ] Verifierat mappnamnet: `booklore-sync.koplugin` (med .koplugin)
- [ ] Verifierat att `_meta.lua` och `main.lua` finns i mappen
- [ ] Startat om KOReader (inte bara stängt en bok)
- [ ] Testat minimal version (`test-minimal.lua` → `main.lua`)
- [ ] Kollat crash.log efter felmeddelanden
- [ ] Försökt hitta andra .koplugin-mappar och lagt pluginet där
- [ ] Verifierat KOReader-version (minst v2021.04)

## 🆘 Om inget fungerar

Skicka denna information:

1. **Var la du pluginet?** (fullständig sökväg)
2. **Vad säger crash.log?** (om något)
3. **Vilken KOReader-version?** (Hjälp → Om)
4. **Andra plugins fungerar?** (vilka?)
5. **Bigme B7 Pro firmware-version?**
6. **Har du provat minimal version?** (test-minimal.lua)
