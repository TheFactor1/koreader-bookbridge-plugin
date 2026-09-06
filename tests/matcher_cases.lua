local function words(t) local l=sortedWordList(normalizeTitleWords(t)) return table.concat(l," ") end
local catalog = { __authors = {} }
for _, a in ipairs({"Pierce Brown","Cormac McCarthy","Cixin Liu","Blake Crouch","Matt Dinniman","Rebecca Yarros","Frank Herbert","Stan Lee","Tom Stechschulte"}) do
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
}
for _, c in ipairs(cases) do
  local got = sub(c[1], c[2], c[3]); local ok = (got == c[4]); if not ok then fails = fails + 1 end
  print((ok and "PASS" or "FAIL") .. "  match  title[" .. c[1] .. "] file[" .. c[3] .. "] -> " .. tostring(got))
end
print("=== " .. fails .. " failure(s)")
os.exit(fails == 0 and 0 or 1)
