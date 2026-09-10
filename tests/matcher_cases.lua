local function words(t) local l=sortedWordList(normalizeTitleWords(t)) return table.concat(l," ") end
local catalog = { __authors = {} }
for _, a in ipairs({"Pierce Brown","Cormac McCarthy","Cixin Liu","Blake Crouch","Matt Dinniman","Rebecca Yarros","Frank Herbert","Stan Lee","Tom Stechschulte","Sarah J. Maas"}) do
  catalog.__authors[words(a)] = true
end
local fails = 0
local function expectQ(fname, want)
  local q = deriveQuery(fname, catalog)
  local ok = (q and q:gsub("%s+$", "") == want)  -- trailing space is harmless: CWA strips it (verified live)
  if not ok then fails = fails + 1 end
  print((ok and "PASS" or "FAIL") .. "  query  " .. fname .. "  ->  [" .. tostring(q) .. "]" .. (ok and "" or ("  expected [" .. want .. "]")))
end
local function expectW(a, b, same)
  local wa, wb = words(a), words(b)
  local ok = ((wa == wb) == same)
  if not ok then fails = fails + 1 end
  print((ok and "PASS" or "FAIL") .. "  words  [" .. a .. "] vs [" .. b .. "] -> {" .. wa .. "} {" .. wb .. "}")
end
print("--- query derivation (the Spider-Man / hyphen fix + regression set)")
expectQ("Spider-Man - Stan Lee", "Spider-Man")
expectQ("The Three-Body Problem - Cixin Liu", "The Three-Body Problem")
expectQ("Cixin Liu - The Three-Body Problem", "The Three-Body Problem")
expectQ("The Dark Forest (The Three-Body Problem Series Book 2) - Cixin Liu", "The Dark Forest")
expectQ("Pierce Brown - Iron Gold_ Book IV of the Red Rising Saga", "Iron Gold")
expectQ("The Dungeon Anarchist's Cookbook_ Dungeon Crawler Carl Book 3 - Matt Dinniman", "The Dungeon Anarchist's Cookbook")
expectQ("Carl's Doomsday Scenario_ Dungeon Crawler Carl Book 2 - Matt Dinniman", "Carl's Doomsday Scenario")
-- Series-volume mangling ("<Series> <N>_ <Title>"): the real title is AFTER
-- the number, not before it. A digit right before the "_" is what tells this
-- apart from the colon mangling above (word before "_", title before it).
expectQ("Sarah J. Maas - Court of Thorns and Roses 2_ A Court Of Mist And Fury", "A Court Of Mist And Fury")
-- Same shape with an author the CWA catalog does NOT know: the author-side
-- detection would pick "Nobody Known" as the title, but the "N_ " marker
-- proves which side is the title, so the real title still wins.
expectQ("Nobody Known - Some Series 3_ The Real Title", "The Real Title")
expectQ("Dune Messiah - Frank Herbert", "Dune Messiah")
expectQ("Fourth Wing (Rebecca Yarros) (z-library.sk, 1lib.sk, z-lib.sk)", "Fourth Wing")
expectQ("Road, The - Cormac McCarthy", "Road, The")
expectQ("McCarthy, Stechschulte - The Road", "The Road")
expectQ("Dark Age - Pierce Brown", "Dark Age")
expectQ("Recursion Blake Crouch Z-Library", "Recursion Blake Crouch Z-Library")
print("--- word normalization (diacritics, curly quotes, underscore, non-Latin)")
expectW("The Handmaid\226\128\153s Tale", "The Handmaid's Tale", true)
expectW("Ender\226\128\153s Game", "Ender's Game", true)
expectW("Les Mis\195\169rables", "Les Miserables", true)
expectW("Red Rising 4_ Iron Gold", "Red Rising 4: Iron Gold", true)
expectW("Iron Gold", "Pierce Brown", false)
expectW("Dark Age", "Dark Matter", false)
expectW("Spider-Man", "Spider Man", true)
expectW("Carl's Doomsday Scenario: Dungeon Crawler Carl Book 2", "Carl's Doomsday Scenario_ Dungeon Crawler Carl (Book 2) - Matt Dinniman", false)  -- author words differ, but title side must be a subset (checked below)
expectW("The Book Thief", "The Thief", false)
expectW("Wool Book 12", "Wool Book 13", false)
-- Volume numbers are deliberately NOT words (see volumeNumbersOf); the
-- compatibility gate in doSyncLibrary handles them. These pin its parsing.
local function expectVols(text, want)
  local nums = volumeNumbersOf(text)
  local got = {}
  for n in pairs(nums) do got[#got + 1] = n end
  table.sort(got)
  local ok = (table.concat(got, ",") == want)
  if not ok then fails = fails + 1 end
  print((ok and "PASS" or "FAIL") .. "  vols   [" .. text .. "] -> {" .. table.concat(got, ",") .. "}" .. (ok and "" or ("  expected {" .. want .. "}")))
end
expectVols("Dungeon Crawler Carl Book 2", "2")
expectVols("Dungeon Crawler Carl: A LitRPG/Gamelit Adventure", "")
expectVols("Carl's Doomsday Scenario_ Dungeon Crawler Carl (Book 2) - Matt Dinniman", "2")
expectVols("The Dark Tower I: The Gunslinger (1)", "1")
expectVols("The Dark Tower - Stephen King", "")
expectVols("I Am Legend - Richard Matheson", "")
expectVols("Pierce Brown - Iron Gold_ Book IV of the Red Rising Saga", "4")
expectVols("Wayward Pines - 02 Wayward - Blake Crouch [Crouch, Blake]", "2")
expectVols("1984 - George Orwell", "")
expectVols("Fahrenheit 451", "451")
expectVols("Stephen King - 11_22_63_ A Novel", "11,22,63")
expectVols("Civil War - Anonymous", "")
local cyr = words("\208\146\208\190\208\185\208\189\208\176 \208\184 \208\188\208\184\209\128")
print((cyr ~= "" and "PASS" or "FAIL") .. "  cyrillic title keeps words: {" .. cyr .. "}")
if cyr == "" then fails = fails + 1 end
print("--- subset matcher")
local function sub(t,a,f) return titleWordsSubsetOf(normalizeTitleWords(t), normalizeTitleWords(a), normalizeTitleWords(f)) end
local cases = {
  {"Dark Matter","Blake Crouch","Dark Age - Pierce Brown", false},
  {"Dark Age","Pierce Brown","Dark Age - Pierce Brown", true},
  {"Mistborn","Brandon Sanderson","Mistborn - The Well of Ascension - Brandon Sanderson", false},
  {"The Three-Body Problem","Cixin Liu","Cixin Liu - The Three-Body Problem", true},
  {"Carl's Doomsday Scenario: Dungeon Crawler Carl Book 2","Matt Dinniman","Carl's Doomsday Scenario_ Dungeon Crawler Carl (Book 2) - Matt Dinniman", true},
  {"The Book Thief","Markus Zusak","The Thief - Markus Zusak", false},
  {"Dungeon Crawler Carl: A LitRPG/Gamelit Adventure","Matt Dinniman","Dungeon Crawler Carl Book 2 - Matt Dinniman", false},
}
for _, c in ipairs(cases) do
  local got = sub(c[1], c[2], c[3]); local ok = (got == c[4]); if not ok then fails = fails + 1 end
  print((ok and "PASS" or "FAIL") .. "  match  title[" .. c[1] .. "] file[" .. c[3] .. "] -> " .. tostring(got))
end
print("=== " .. fails .. " failure(s)")
os.exit(fails == 0 and 0 or 1)
