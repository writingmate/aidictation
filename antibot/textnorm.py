"""Text normalization shared by training and the API.

Strips formatting that differs by source rather than by author: line breaks, link
targets, quote markers and typographic punctuation. Otherwise the model learns where
a comment was scraped from instead of how it was written.
"""
import re

_URL = re.compile(r"https?://\S+|www\.\S+")
_QUOTE_LINE = re.compile(r"(?m)^\s*>.*$")
_SPACED_PUNCT = re.compile(r"\s+([.,!?;:%)\]])")
_SPACED_OPEN = re.compile(r"([(\[])\s+")
_SPACED_CONTRACTION = re.compile(r"\s+(n't|'s|'re|'ve|'ll|'d|'m)\b", re.I)
_SPACED_QUOTES = re.compile(r'"\s+([^"]*?)\s+"')
_TYPOGRAPHY = str.maketrans({"’": "'", "‘": "'", "“": '"', "”": '"', "—": "-", "–": "-", "…": "..."})


def detokenize(text):
    """Undo the tokenizer spacing HC3 applied to its human answers ("word ." and "do n't")."""
    text = _SPACED_CONTRACTION.sub(r"\1", text)
    text = _SPACED_QUOTES.sub(r'"\1"', text)
    text = _SPACED_OPEN.sub(r"\1", text)
    return _SPACED_PUNCT.sub(r"\1", text)


def normalize(text):
    text = _QUOTE_LINE.sub(" ", text)
    text = _URL.sub(" urltoken ", text)
    text = text.translate(_TYPOGRAPHY)
    return re.sub(r"\s+", " ", text).strip().lower()
