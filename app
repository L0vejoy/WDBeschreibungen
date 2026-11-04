import re
import urllib.parse
from bs4 import BeautifulSoup
import requests
import streamlit as st

# Seiten-Layout konfigurieren
st.set_page_config(
    page_title="TXT-Liste Personendaten zu Wikidata",
    page_icon="🌐",
    layout="centered",
)

st.title("Wikipedia Textdatei $\\rightarrow$ Wikidata (Deutsche Beschreibung)")
st.write(
    "Dieses Tool liest Wikipedia-Titel aus einer .txt-Datei ein, prüft"
    " Wikidata auf fehlende deutsche Beschreibungen, extrahiert die"
    " Kurzbeschreibung aus dem Wikitext-Template und bereitet QuickStatements"
    " vor."
)

HEADERS = {
    "User-Agent": (
        "WikidataDescriptionChecker/1.0 (Educational Script;"
        " https://de.wikipedia.org)"
    )
}


def check_wikidata_descriptions(wiki_titles):
  """Prüft via Wikidata, ob eine deutsche Beschreibung (descriptions.de) vorhanden ist."""
  S = requests.Session()
  S.headers.update(HEADERS)
  url = "https://www.wikidata.org/w/api.php"
  batch_size = 50
  missing_description = []

  progress_text = st.empty()
  total_batches = (len(wiki_titles) + batch_size - 1) // batch_size
  current_batch = 0

  for i in range(0, len(wiki_titles), batch_size):
    current_batch += 1
    progress_text.text(
        f"Prüfe Wikidata-Batch {current_batch} von {total_batches}..."
    )

    batch = wiki_titles[i : i + batch_size]
    titles_str = "|".join(batch)
    params = {
        "action": "wbgetentities",
        "sites": "dewiki",
        "titles": titles_str,
        "props": "descriptions|sitelinks",
        "format": "json",
    }
    try:
      response = S.get(url=url, params=params)
      response.raise_for_status()
      data = response.json()
      entities = data.get("entities", {})
      for entity_id, entity_data in entities.items():
        if entity_id.startswith("Q"):
          descriptions = entity_data.get("descriptions", {})
          has_de_desc = "de" in descriptions

          sitelinks = entity_data.get("sitelinks", {})
          dewiki_title = (
              sitelinks.get("dewiki", {}).get("title")
              or entity_data.get("title")
              or entity_id
          )

          if not has_de_desc:
            missing_description.append((entity_id, dewiki_title))
    except Exception as e:
      print(f"Fehler bei Wikidata: {e}")

  progress_text.empty()
  return missing_description


def extract_personendaten_from_wikitext(wikitext):
  """Extrahiert das Feld 'KURZBESCHREIBUNG' oder 'BESCHREIBUNG' robust aus dem Wikitext."""
  match = re.search(
      r"\|\s*(?:KURZBESCHREIBUNG|kurzbeschreibung|BESCHREIBUNG|beschreibung)\s*=\s*([^\n\|\}]+)",
      wikitext,
      re.IGNORECASE
  )
  if match:
    beschreibung = match.group(1).strip()
    beschreibung = re.sub(r"\[\[(?:[^\]\|]*\|)?([^\]]+)\]\]", r"\1", beschreibung)
    beschreibung = re.sub(r"<!--.*?-->", "", beschreibung).strip()
    
    if beschreibung and beschreibung.lower() not in ("-', '", "-", "none", "", "unbekannt"):
      return beschreibung

  return None


# Session-State initialisieren
if "batch_items" not in st.session_state:
  st.session_state.batch_items = []

# Dateiupload-Komponente in Streamlit
uploaded_file = st.file_uploader(
    "Wähle eine Textdatei (.txt) mit Wikipedia-Artikeln aus", type=["txt"]
)

if uploaded_file is not None:
  string_data = uploaded_file.getvalue().decode("utf-8")
  titles = [
      line.strip() for line in string_data.splitlines() if line.strip()
  ]

  st.info(f"Gefundene Artikel in der Textdatei: {len(titles)}")

  if st.button("TXT-Liste einlesen & Personendaten prüfen", type="primary"):
    if titles:
      missing_entries = check_wikidata_descriptions(titles)
      st.info(
          f"Davon Wikidata-Einträge ohne deutsche Beschreibung:"
          f" {len(missing_entries)}"
      )

      st.session_state.batch_items = []
      api_url = "https://de.wikipedia.org/w/api.php"

      progress_bar = st.progress(0)
      total_missing = len(missing_entries)

      for idx, (qid, seiten_titel) in enumerate(missing_entries):
        query_params = {
            "action": "query",
            "titles": seiten_titel,
            "prop": "revisions",
            "rvprop": "content",
            "rvslots": "main",
            "redirects": 1,
            "format": "json",
        }
        try:
          data = requests.get(
              api_url, params=query_params, headers=HEADERS
          ).json()
          pages = data.get("query", {}).get("pages", {})

          wikitext = ""
          for page_id, page_data in pages.items():
            if "revisions" in page_data:
              slot = page_data["revisions"][0].get("slots", {}).get("main", {})
              wikitext = slot.get("*", "") or page_data["revisions"][0].get("*", "")

          if not wikitext:
            continue

          pers_desc = extract_personendaten_from_wikitext(wikitext)

          if not pers_desc:
            continue

          qs_code = f'{qid}|Dde|"{pers_desc}"'

          st.session_state.batch_items.append({
              "titel": seiten_titel,
              "qid": qid,
              "beschreibung": pers_desc,
              "qs": qs_code,
              "selected": True,
          })
        except Exception:
          continue

        if total_missing > 0:
          progress_bar.progress((idx + 1) / total_missing)

      progress_bar.empty()
      st.success(
          f"Fertig! {len(st.session_state.batch_items)} passende Einträge mit"
          " Personendaten gefunden."
      )

# Anzeige der Liste mit Checkboxen (alle standardmäßig vorausgewählt)
if st.session_state.batch_items:
  st.markdown("---")
  st.subheader("Gefundene QuickStatements-Befehle (Vorausgewählt)")

  selected_qs_list = []

  for idx, item in enumerate(st.session_state.batch_items):
    col1, col2 = st.columns([0.1, 0.9])
    with col1:
      is_checked = st.checkbox(
          "Auswahl",
          value=item["selected"],
          key=f"check_{idx}",
          label_visibility="collapsed",
      )
      st.session_state.batch_items[idx]["selected"] = is_checked
    with col2:
      st.markdown(f"**{item['titel']}** (`{item['qid']}`) – Beschreibung: `{item['beschreibung']}`")
      st.code(item["qs"], language="text")

    if is_checked:
      selected_qs_list.append(item["qs"])

  # Native QuickStatements-Ausgabe mit integriertem Streamlit-Code-Kopierer und Link-Button
  if selected_qs_list:
    combined_qs = "\n".join(selected_qs_list)
    qs_url = "https://qs-dev.toolforge.org/batch/new/"

    st.markdown("---")
    st.subheader("📋 QuickStatements-Batch bereit")
    st.write(
        "Klicke oben rechts im folgenden Code-Block auf das **Kopier-Symbol**,"
        " um alle ausgewählten Befehle in die Zwischenablage zu kopieren:"
    )
    
    st.code(combined_qs, language="text")

    st.link_button(
        "🚀 Zu QS-Dev (QuickStatements Batch) wechseln",
        qs_url,
        type="primary",
        help="Öffnet die QuickStatements-Batch-Oberfläche in einem neuen Tab"
    )
  else:
    st.warning("Bitte wähle mindestens einen Eintrag über die Checkboxen aus.")
