#!/usr/bin/env python3
"""The MC68030 User's Manual, 3rd ed. (1990), Section 11.6: the instruction
timing tables, transcribed from the page images (C:/temp/Mac/SE30/Docs/
MC68030_Users_Manual_3ed_1990.pdf, pages 11-26 to 11-51) on 2026-10-03 for
SE30_PLAN.md 1.17.5 - the paced kernel's reference.  Every row is
(head, tail, I-cache case, no-cache case, reads, prefetches, writes); the
r/p/w are the no-cache case's where the two differ in the manual (the
manual lists both; the I-cache case's prefetches are always 0).  Rows
whose head the manual gives as "n + op head" carry n and ophead True.
"%" rows (no clocks for the fetch) are included with 0.

The manual's model: UM 11.3 Equation 11-2 for the cache case (sim/system/
report_time.py applies it).
"""


def row(head, tail, cc, ncc, r, p, w, ophead=False):
    return dict(head=head, tail=tail, cc=cc, ncc=ncc, r=r, p=p, w=w, ophead=ophead)


# 11.6.1 Fetch Effective Address (fea), pp. 11-26, 11-27
FEA = {
    "Dn":                 row(0, 0, 0, 0, 0, 0, 0),      # %
    "An":                 row(0, 0, 0, 0, 0, 0, 0),      # %
    "(An)":               row(1, 1, 3, 3, 1, 0, 0),
    "(An)+":              row(0, 1, 3, 3, 1, 0, 0),
    "-(An)":              row(2, 2, 4, 4, 1, 0, 0),
    "(d16,An)":           row(2, 2, 4, 4, 1, 1, 0),      # or (d16,PC)
    "(xxx).W":            row(2, 2, 4, 4, 1, 1, 0),
    "(xxx).L":            row(1, 0, 4, 5, 1, 1, 0),
    "#(data).B":          row(2, 0, 2, 2, 0, 1, 0),
    "#(data).W":          row(2, 0, 2, 2, 0, 1, 0),
    "#(data).L":          row(4, 0, 4, 4, 0, 1, 0),
    # brief format extension word
    "(d8,An,Xn)":         row(4, 2, 6, 6, 1, 1, 0),      # or (d8,PC,Xn)
    # full format extension word(s); B = base (0, An, PC, Xn, An+Xn, PC+Xn), I = index (0, Xn)
    "(d16,An) full":      row(2, 0, 6, 7, 1, 1, 0),
    "(d16,An,Xn) full":   row(4, 0, 6, 7, 1, 1, 0),
    "([d16,An])":         row(2, 0, 10, 10, 2, 1, 0),
    "([d16,An],Xn)":      row(2, 0, 10, 10, 2, 1, 0),
    "([d16,An],d16)":     row(2, 0, 12, 13, 2, 2, 0),
    "([d16,An],Xn,d16)":  row(2, 0, 12, 13, 2, 2, 0),
    "([d16,An],d32)":     row(2, 0, 12, 14, 2, 2, 0),
    "([d16,An],Xn,d32)":  row(2, 0, 12, 14, 2, 2, 0),
    "(B)":                row(4, 0, 6, 7, 1, 1, 0),
    "(d16,B)":            row(4, 0, 8, 10, 1, 1, 0),
    "(d32,B)":            row(4, 0, 12, 13, 1, 2, 0),
    "([B])":              row(4, 0, 10, 10, 2, 1, 0),
    "([B],I)":            row(4, 0, 10, 10, 2, 1, 0),
    "([B],d16)":          row(4, 0, 12, 13, 2, 1, 0),
    "([B],I,d16)":        row(4, 0, 12, 13, 2, 1, 0),
    "([B],d32)":          row(4, 0, 12, 14, 2, 2, 0),
    "([B],I,d32)":        row(4, 0, 12, 14, 2, 2, 0),
    "([d16,B])":          row(4, 0, 12, 13, 2, 1, 0),
    "([d16,B],I)":        row(4, 0, 12, 13, 2, 1, 0),
    "([d16,B],d16)":      row(4, 0, 14, 16, 2, 2, 0),
    "([d16,B],I,d16)":    row(4, 0, 14, 16, 2, 2, 0),
    "([d16,B],d32)":      row(4, 0, 14, 17, 2, 2, 0),
    "([d16,B],I,d32)":    row(4, 0, 14, 17, 2, 2, 0),
    "([d32,B])":          row(4, 0, 16, 17, 2, 2, 0),
    "([d32,B],I)":        row(4, 0, 16, 17, 2, 2, 0),
    "([d32,B],d16)":      row(4, 0, 18, 20, 2, 2, 0),
    "([d32,B],I,d16)":    row(4, 0, 18, 20, 2, 2, 0),
    "([d32,B],d32)":      row(4, 0, 18, 21, 2, 3, 0),
    "([d32,B],I,d32)":    row(4, 0, 18, 21, 2, 3, 0),
}

# 11.6.2 Fetch Immediate Effective Address (fiea), pp. 11-28 to 11-30: the
# immediate source fetched and the destination calculated and fetched
# (or, for two-word instructions, the second word and the single operand)
FIEA = {
    "#.W,Dn":             row(2, 0, 2, 2, 0, 1, 0, True),   # % head includes the op head
    "#.L,Dn":             row(4, 0, 4, 4, 0, 1, 0, True),
    "#.W,(An)":           row(1, 1, 3, 4, 1, 1, 0),
    "#.L,(An)":           row(1, 0, 4, 5, 1, 1, 0),
    "#.W,(An)+":          row(2, 1, 5, 5, 1, 1, 0),
    "#.L,(An)+":          row(4, 1, 7, 7, 1, 1, 0),
    "#.W,-(An)":          row(2, 2, 4, 4, 1, 1, 0),
    "#.L,-(An)":          row(2, 0, 4, 5, 1, 1, 0),
    "#.W,(d16,An)":       row(2, 0, 4, 5, 1, 1, 0),
    "#.L,(d16,An)":       row(4, 0, 6, 8, 1, 2, 0),
    "#.W,(xxx).W":        row(4, 2, 6, 6, 1, 1, 0),
    "#.L,(xxx).W":        row(6, 2, 8, 8, 1, 2, 0),
    "#.W,(xxx).L":        row(3, 0, 6, 7, 1, 2, 0),
    "#.L,(xxx).L":        row(5, 0, 8, 9, 1, 2, 0),
    "#.W,#.L":            row(6, 0, 6, 6, 0, 2, 0, True),
    "#.W,(d8,An,Xn)":     row(6, 2, 8, 8, 1, 2, 0),
    "#.L,(d8,An,Xn)":     row(8, 2, 10, 10, 1, 2, 0),
    "#.W,(d16,An) full":  row(4, 0, 8, 9, 1, 2, 0),
    "#.L,(d16,An) full":  row(6, 0, 10, 11, 1, 2, 0),
    "#.W,(d16,An,Xn) full": row(6, 0, 8, 9, 1, 2, 0),
    "#.L,(d16,An,Xn) full": row(8, 0, 10, 11, 1, 2, 0),
    "#.W,([d16,An])":     row(4, 0, 12, 12, 2, 2, 0),
    "#.L,([d16,An])":     row(6, 0, 14, 14, 2, 2, 0),
    "#.W,([d16,An],Xn)":  row(4, 0, 12, 12, 2, 2, 0),
    "#.L,([d16,An],Xn)":  row(6, 0, 14, 14, 2, 2, 0),
    "#.W,([d16,An],d16)": row(4, 0, 14, 15, 2, 2, 0),
    "#.L,([d16,An],d16)": row(6, 0, 16, 17, 2, 3, 0),
    "#.W,([d16,An],Xn,d16)": row(4, 0, 14, 15, 2, 2, 0),
    "#.L,([d16,An],Xn,d16)": row(6, 0, 16, 17, 2, 3, 0),
    "#.W,([d16,An],d32)": row(4, 0, 14, 16, 2, 3, 0),
    "#.L,([d16,An],d32)": row(6, 0, 16, 18, 2, 3, 0),
    "#.W,([d16,An],Xn,d32)": row(4, 0, 14, 16, 2, 3, 0),
    "#.L,([d16,An],Xn,d32)": row(6, 0, 16, 18, 2, 3, 0),
    "#.W,(B)":            row(6, 0, 8, 9, 1, 1, 0),
    "#.L,(B)":            row(8, 0, 10, 11, 1, 2, 0),
    "#.W,(d16,B)":        row(6, 0, 10, 12, 1, 2, 0),
    "#.L,(d16,B)":        row(8, 0, 12, 14, 1, 2, 0),
    "#.W,(d32,B)":        row(10, 0, 14, 16, 1, 2, 0),
    "#.L,(d32,B)":        row(12, 0, 16, 18, 1, 3, 0),
    "#.W,([B])":          row(6, 0, 12, 12, 2, 1, 0),
    "#.L,([B])":          row(8, 0, 14, 14, 2, 2, 0),
    "#.W,([B],I)":        row(6, 0, 12, 12, 2, 1, 0),
    "#.L,([B],I)":        row(8, 0, 14, 14, 2, 2, 0),
    "#.W,([B],d16)":      row(6, 0, 14, 15, 2, 2, 0),
    "#.L,([B],d16)":      row(8, 0, 16, 17, 2, 2, 0),
    "#.W,([B],I,d16)":    row(6, 0, 14, 15, 2, 2, 0),
    "#.L,([B],I,d16)":    row(8, 0, 16, 17, 2, 2, 0),
    "#.W,([B],d32)":      row(6, 0, 14, 16, 2, 2, 0),
    "#.L,([B],d32)":      row(8, 0, 16, 18, 2, 3, 0),
    "#.W,([B],I,d32)":    row(6, 0, 14, 16, 2, 2, 0),
    "#.L,([B],I,d32)":    row(8, 0, 16, 18, 2, 3, 0),
    "#.W,([d16,B])":      row(6, 0, 14, 15, 2, 2, 0),
    "#.L,([d16,B])":      row(8, 0, 16, 17, 2, 2, 0),
    "#.W,([d16,B],I)":    row(6, 0, 14, 15, 2, 2, 0),
    "#.L,([d16,B],I)":    row(8, 0, 16, 17, 2, 2, 0),
    "#.W,([d16,B],d16)":  row(6, 0, 16, 18, 2, 2, 0),
    "#.L,([d16,B],d16)":  row(8, 0, 18, 20, 2, 3, 0),
    "#.W,([d16,B],I,d16)": row(6, 0, 16, 18, 2, 2, 0),
    "#.L,([d16,B],I,d16)": row(8, 0, 18, 20, 2, 3, 0),
    "#.W,([d16,B],d32)":  row(6, 0, 16, 19, 2, 3, 0),
    "#.L,([d16,B],d32)":  row(8, 0, 18, 21, 2, 3, 0),
    "#.W,([d16,B],I,d32)": row(6, 0, 16, 19, 2, 3, 0),
    "#.L,([d16,B],I,d32)": row(8, 0, 18, 21, 2, 3, 0),
    "#.W,([d32,B])":      row(6, 0, 18, 19, 2, 2, 0),
    "#.L,([d32,B])":      row(8, 0, 20, 21, 2, 3, 0),
    "#.W,([d32,B],I)":    row(6, 0, 18, 19, 2, 2, 0),
    "#.L,([d32,B],I)":    row(8, 0, 20, 21, 2, 3, 0),
    "#.W,([d32,B],d16)":  row(6, 0, 20, 22, 2, 3, 0),
    "#.L,([d32,B],d16)":  row(8, 0, 22, 24, 2, 3, 0),
    "#.W,([d32,B],I,d16)": row(6, 0, 20, 22, 2, 3, 0),
    "#.L,([d32,B],I,d16)": row(8, 0, 22, 24, 2, 3, 0),
    "#.W,([d32,B],d32)":  row(6, 0, 20, 23, 2, 3, 0),
    "#.L,([d32,B],d32)":  row(8, 0, 22, 25, 2, 4, 0),
    "#.W,([d32,B],I,d32)": row(6, 0, 20, 23, 2, 3, 0),
    "#.L,([d32,B],I,d32)": row(8, 0, 22, 25, 2, 4, 0),
}

# 11.6.3 Calculate Effective Address (cea), pp. 11-30 to 11-32 (no operand
# fetch; the first level of a memory indirect mode is fetched)
CEA = {
    "Dn":                 row(0, 0, 0, 0, 0, 0, 0),      # %
    "An":                 row(0, 0, 0, 0, 0, 0, 0),      # %
    "(An)":               row(2, 0, 2, 2, 0, 0, 0, True),
    "(An)+":              row(0, 0, 2, 2, 0, 0, 0),
    "-(An)":              row(2, 0, 2, 2, 0, 0, 0, True),
    "(d16,An)":           row(2, 0, 2, 2, 0, 1, 0, True),
    "(xxx).W":            row(2, 0, 2, 2, 0, 1, 0, True),
    "(xxx).L":            row(4, 0, 4, 4, 0, 1, 0, True),
    "(d8,An,Xn)":         row(4, 0, 4, 4, 0, 1, 0, True),
    "(d16,An) full":      row(2, 0, 6, 6, 0, 1, 0),
    "(d16,An,Xn) full":   row(6, 0, 6, 6, 0, 1, 0, True),
    "([d16,An])":         row(2, 0, 10, 10, 1, 1, 0),
    "([d16,An],Xn)":      row(2, 0, 10, 10, 1, 1, 0),
    "([d16,An],d16)":     row(2, 0, 12, 13, 1, 2, 0),
    "([d16,An],Xn,d16)":  row(2, 0, 12, 13, 1, 2, 0),
    "([d16,An],d32)":     row(2, 0, 12, 13, 1, 2, 0),
    "([d16,An],Xn,d32)":  row(2, 0, 12, 13, 1, 2, 0),
    "(B)":                row(6, 0, 6, 6, 0, 1, 0, True),
    "(d16,B)":            row(4, 0, 8, 9, 0, 1, 0),
    "(d32,B)":            row(4, 0, 12, 12, 0, 2, 0),
    "([B])":              row(4, 0, 10, 10, 1, 1, 0),
    "([B],I)":            row(4, 0, 10, 10, 1, 1, 0),
    "([B],d16)":          row(4, 0, 12, 13, 1, 1, 0),
    "([B],I,d16)":        row(4, 0, 12, 13, 1, 1, 0),
    "([B],d32)":          row(4, 0, 12, 13, 1, 2, 0),
    "([B],I,d32)":        row(4, 0, 12, 13, 2, 2, 0),    # as printed (2 reads where its neighbours have 1)
    "([d16,B])":          row(4, 0, 12, 13, 1, 1, 0),
    "([d16,B],I)":        row(4, 0, 12, 13, 1, 1, 0),
    "([d16,B],d16)":      row(4, 0, 14, 16, 1, 2, 0),
    "([d16,B],I,d16)":    row(4, 0, 14, 16, 1, 2, 0),
    "([d16,B],d32)":      row(4, 0, 14, 16, 1, 2, 0),
    "([d16,B],I,d32)":    row(4, 0, 14, 16, 1, 2, 0),
    "([d32,B])":          row(4, 0, 16, 17, 1, 2, 0),
    "([d32,B],I)":        row(4, 0, 16, 17, 1, 2, 0),
    "([d32,B],d16)":      row(4, 0, 18, 20, 1, 2, 0),
    "([d32,B],I,d16)":    row(4, 0, 18, 20, 1, 2, 0),
    "([d32,B],d32)":      row(4, 0, 18, 20, 1, 3, 0),
    "([d32,B],I,d32)":    row(4, 0, 18, 20, 1, 3, 0),
}

# 11.6.4 Calculate Immediate Effective Address (ciea), pp. 11-32 to 11-35:
# the immediate source fetched, the destination calculated (not fetched)
CIEA = {
    "#.W,Dn":             row(2, 0, 2, 2, 0, 1, 0, True),   # %
    "#.L,Dn":             row(4, 0, 4, 4, 0, 1, 0, True),
    "#.W,(An)":           row(2, 0, 2, 2, 0, 1, 0, True),
    "#.L,(An)":           row(4, 0, 4, 4, 0, 1, 0, True),
    "#.W,(An)+":          row(2, 0, 4, 4, 0, 1, 0),
    "#.L,(An)+":          row(4, 0, 6, 6, 0, 1, 0),
    "#.W,-(An)":          row(2, 0, 2, 2, 0, 1, 0, True),
    "#.L,-(An)":          row(4, 0, 4, 4, 0, 1, 0, True),
    "#.W,(d16,An)":       row(4, 0, 4, 4, 0, 1, 0, True),
    "#.L,(d16,An)":       row(6, 0, 6, 7, 0, 2, 0, True),
    "#.W,(xxx).W":        row(4, 0, 4, 4, 0, 1, 0, True),
    "#.L,(xxx).W":        row(6, 0, 6, 6, 0, 2, 0, True),
    "#.W,(xxx).L":        row(6, 0, 6, 6, 0, 2, 0, True),
    "#.L,(xxx).L":        row(8, 0, 8, 8, 0, 2, 0, True),
    "#.W,(d8,An,Xn)":     row(6, 0, 6, 6, 0, 2, 0, True),
    "#.L,(d8,An,Xn)":     row(8, 0, 8, 8, 0, 2, 0, True),
    "#.W,(d16,An) full":  row(4, 0, 8, 8, 0, 2, 0),
    "#.L,(d16,An) full":  row(6, 0, 10, 10, 0, 2, 0),
    "#.W,(d16,An,Xn) full": row(8, 0, 8, 8, 0, 2, 0, True),
    "#.L,(d16,An,Xn) full": row(10, 0, 10, 10, 0, 2, 0, True),
    "#.W,([d16,An])":     row(4, 0, 12, 12, 1, 2, 0),
    "#.L,([d16,An])":     row(6, 0, 14, 14, 1, 1, 0),
    "#.W,([d16,An],Xn)":  row(4, 0, 12, 12, 1, 2, 0),
    "#.L,([d16,An],Xn)":  row(6, 0, 14, 14, 1, 1, 0),
    "#.W,([d16,An],d16)": row(4, 0, 14, 15, 1, 2, 0),
    "#.L,([d16,An],d16)": row(6, 0, 16, 17, 1, 3, 0),
    "#.W,([d16,An],Xn,d16)": row(4, 0, 14, 15, 1, 2, 0),
    "#.L,([d16,An],Xn,d16)": row(6, 0, 16, 17, 1, 3, 0),
    "#.W,([d16,An],d32)": row(4, 0, 14, 16, 1, 3, 0),
    "#.L,([d16,An],d32)": row(6, 0, 16, 17, 1, 3, 0),
    "#.W,([d16,An],Xn,d32)": row(4, 0, 14, 15, 1, 3, 0),
    "#.L,([d16,An],Xn,d32)": row(6, 0, 16, 17, 1, 3, 0),
    "#.W,(B)":            row(8, 0, 8, 8, 0, 1, 0, True),
    "#.L,(B)":            row(10, 0, 10, 10, 0, 2, 0, True),
    "#.W,(d16,B)":        row(6, 0, 10, 11, 0, 2, 0),
    "#.L,(d16,B)":        row(8, 0, 12, 13, 0, 2, 0),
    "#.W,(d32,B)":        row(6, 0, 14, 15, 0, 2, 0),
    "#.L,(d32,B)":        row(8, 0, 16, 17, 0, 3, 0),
    "#.W,([B])":          row(6, 0, 12, 12, 1, 1, 0),
    "#.L,([B])":          row(8, 0, 14, 14, 1, 2, 0),
    "#.W,([B],I)":        row(6, 0, 12, 12, 1, 1, 0),
    "#.L,([B],I)":        row(8, 0, 14, 14, 1, 2, 0),
    "#.W,([B],d16)":      row(6, 0, 14, 15, 1, 2, 0),
    "#.L,([B],d16)":      row(8, 0, 16, 17, 1, 2, 0),
    "#.W,([B],I,d16)":    row(6, 0, 14, 15, 1, 2, 0),
    "#.L,([B],I,d16)":    row(8, 0, 16, 17, 1, 2, 0),    # printed 16(2/0/0): as its neighbours, 1 read
    "#.W,([B],d32)":      row(6, 0, 14, 15, 1, 2, 0),
    "#.L,([B],d32)":      row(8, 0, 16, 17, 1, 3, 0),
    "#.W,([B],I,d32)":    row(6, 0, 14, 15, 1, 2, 0),
    "#.L,([B],I,d32)":    row(8, 0, 16, 17, 1, 3, 0),
    "#.W,([d16,B])":      row(6, 0, 14, 15, 1, 2, 0),
    "#.L,([d16,B])":      row(8, 0, 16, 17, 1, 2, 0),
    "#.W,([d16,B],I)":    row(6, 0, 14, 15, 1, 2, 0),
    "#.L,([d16,B],I)":    row(8, 0, 16, 17, 1, 2, 0),
    "#.W,([d16,B],d16)":  row(6, 0, 16, 18, 1, 2, 0),
    "#.L,([d16,B],d16)":  row(8, 0, 18, 20, 1, 3, 0),
    "#.W,([d16,B],I,d16)": row(6, 0, 16, 18, 1, 2, 0),
    "#.L,([d16,B],I,d16)": row(8, 0, 18, 20, 1, 3, 0),
    "#.W,([d16,B],d32)":  row(6, 0, 16, 18, 1, 3, 0),
    "#.L,([d16,B],d32)":  row(8, 0, 18, 20, 1, 3, 0),
    "#.W,([d16,B],I,d32)": row(6, 0, 16, 18, 1, 3, 0),
    "#.L,([d16,B],I,d32)": row(8, 0, 18, 20, 1, 3, 0),
    "#.W,([d32,B])":      row(6, 0, 18, 19, 1, 2, 0),
    "#.L,([d32,B])":      row(8, 0, 20, 21, 1, 3, 0),
    "#.W,([d32,B],I)":    row(6, 0, 18, 19, 1, 2, 0),
    "#.L,([d32,B],I)":    row(8, 0, 20, 21, 1, 3, 0),
    "#.W,([d32,B],d16)":  row(6, 0, 20, 22, 1, 3, 0),
    "#.L,([d32,B],d16)":  row(8, 0, 22, 24, 1, 3, 0),
    "#.W,([d32,B],I,d16)": row(6, 0, 20, 22, 1, 3, 0),
    "#.L,([d32,B],I,d16)": row(8, 0, 22, 24, 1, 3, 0),
    "#.W,([d32,B],d32)":  row(6, 0, 20, 22, 1, 3, 0),
    "#.L,([d32,B],d32)":  row(8, 0, 22, 24, 1, 4, 0),
    "#.W,([d32,B],I,d32)": row(6, 0, 20, 22, 1, 3, 0),
    "#.L,([d32,B],I,d32)": row(8, 0, 22, 24, 1, 4, 0),
}

# 11.6.5 Jump Effective Address (JMP, JSR), pp. 11-35, 11-36
JEA = {
    "(An)":               row(2, 0, 2, 2, 0, 0, 0, True),   # %
    "(d16,An)":           row(4, 0, 4, 4, 0, 0, 0, True),
    "(xxx).W":            row(2, 0, 2, 2, 0, 0, 0, True),
    "(xxx).L":            row(2, 0, 2, 2, 0, 0, 0, True),
    "(d8,An,Xn)":         row(6, 0, 6, 6, 0, 0, 0, True),
    "(d16,An) full":      row(2, 0, 6, 6, 0, 0, 0),
    "(d16,An,Xn) full":   row(6, 0, 6, 6, 0, 0, 0, True),
    "([d16,An])":         row(2, 0, 10, 10, 1, 1, 0),
    "([d16,An],Xn)":      row(2, 0, 10, 10, 1, 1, 0),
    "([d16,An],d16)":     row(2, 0, 12, 12, 1, 1, 0),
    "([d16,An],Xn,d16)":  row(2, 0, 12, 12, 1, 1, 0),
    "([d16,An],d32)":     row(2, 0, 12, 12, 1, 1, 0),
    "([d16,An],Xn,d32)":  row(2, 0, 12, 12, 1, 1, 0),
    "(B)":                row(6, 0, 6, 6, 0, 0, 0, True),
    "(d16,B)":            row(4, 0, 8, 9, 0, 1, 0),
    "(d32,B)":            row(4, 0, 12, 13, 0, 1, 0),
    "([B])":              row(4, 0, 10, 10, 1, 1, 0),
    "([B],I)":            row(4, 0, 10, 10, 1, 1, 0),
    "([B],d16)":          row(4, 0, 12, 12, 1, 1, 0),
    "([B],I,d16)":        row(4, 0, 12, 12, 1, 1, 0),
    "([B],d32)":          row(4, 0, 12, 12, 1, 1, 0),
    "([B],I,d32)":        row(4, 0, 12, 12, 1, 1, 0),
    "([d16,B])":          row(4, 0, 12, 13, 1, 1, 0),
    "([d16,B],I)":        row(4, 0, 12, 13, 1, 1, 0),
    "([d16,B],d16)":      row(4, 0, 14, 15, 1, 1, 0),
    "([d16,B],I,d16)":    row(4, 0, 14, 15, 1, 1, 0),
    "([d16,B],d32)":      row(4, 0, 14, 15, 1, 1, 0),
    "([d16,B],I,d32)":    row(4, 0, 14, 15, 1, 1, 0),
    "([d32,B])":          row(4, 0, 16, 17, 1, 2, 0),
    "([d32,B],I)":        row(4, 0, 16, 17, 1, 2, 0),
    "([d32,B],d16)":      row(4, 0, 18, 19, 1, 2, 0),
    "([d32,B],I,d16)":    row(4, 0, 18, 19, 1, 2, 0),
    "([d32,B],d32)":      row(4, 0, 18, 19, 1, 2, 0),
    "([d32,B],I,d32)":    row(4, 0, 18, 19, 1, 2, 0),
}

# 11.6.6 MOVE, pp. 11-37, 11-38.  "* add fetch EA time" rows carry fea True;
# SOURCE = a memory or immediate source, EA = any
MOVE = {
    "MOVE Rn,Dn":         row(2, 0, 2, 2, 0, 1, 0),
    "MOVE Rn,An":         row(2, 0, 2, 2, 0, 1, 0),
    "MOVE EA,An":         row(0, 0, 2, 2, 0, 1, 0),      # *
    "MOVE EA,Dn":         row(0, 0, 2, 2, 0, 1, 0),      # *
    "MOVE Rn,(An)":       row(0, 1, 3, 4, 0, 1, 1),
    "MOVE SOURCE,(An)":   row(2, 0, 4, 5, 0, 1, 1),      # *
    "MOVE Rn,(An)+":      row(0, 1, 3, 4, 0, 1, 1),
    "MOVE SOURCE,(An)+":  row(2, 0, 4, 5, 0, 1, 1),      # *
    "MOVE Rn,-(An)":      row(0, 2, 4, 4, 0, 1, 1),
    "MOVE SOURCE,-(An)":  row(2, 0, 4, 5, 0, 1, 1),      # *
    "MOVE EA,(d16,An)":   row(2, 0, 4, 5, 0, 1, 1),      # *
    "MOVE EA,(xxx).W":    row(2, 0, 4, 5, 0, 1, 1),      # *
    "MOVE EA,(xxx).L":    row(0, 0, 6, 7, 0, 2, 1),      # *
    "MOVE EA,(d8,An,Xn)": row(4, 0, 6, 7, 0, 1, 1),      # *
    "MOVE EA,(d16,An) full": row(2, 0, 8, 9, 0, 2, 1),
    "MOVE EA,(d16,An,Xn) full": row(2, 0, 8, 9, 0, 2, 1),
    "MOVE EA,([d16,An],Xn)": row(2, 0, 10, 11, 1, 2, 1),
    "MOVE EA,([d16,An],d16)": row(2, 0, 12, 14, 1, 2, 1),
    "MOVE EA,([d16,An],Xn,d16)": row(2, 0, 12, 14, 1, 2, 1),
    "MOVE EA,([d16,An],d32)": row(2, 0, 14, 16, 1, 3, 1),
    "MOVE EA,([d16,An],Xn,d32)": row(2, 0, 14, 16, 1, 3, 1),
    "MOVE EA,(B)":        row(4, 0, 8, 9, 0, 1, 1),
    "MOVE EA,(d16,B)":    row(4, 0, 10, 12, 0, 2, 1),
    "MOVE EA,(d32,B)":    row(4, 0, 14, 16, 0, 2, 1),
    "MOVE EA,([B])":      row(4, 0, 10, 11, 1, 1, 1),
    "MOVE EA,([B],I)":    row(4, 0, 10, 11, 1, 1, 1),
    "MOVE EA,([B],d16)":  row(4, 0, 12, 14, 1, 2, 1),
    "MOVE EA,([B],I,d16)": row(4, 0, 12, 14, 1, 2, 1),
    "MOVE EA,([B],d32)":  row(4, 0, 14, 16, 1, 2, 1),
    "MOVE EA,([B],I,d32)": row(4, 0, 14, 16, 1, 2, 1),
    "MOVE EA,([d16,B])":  row(4, 0, 12, 14, 1, 2, 1),
    "MOVE EA,([d16,B],I)": row(4, 0, 12, 14, 1, 2, 1),
    "MOVE EA,([d16,B],d16)": row(4, 0, 14, 17, 1, 2, 1),
    "MOVE EA,([d16,B],I,d16)": row(4, 0, 14, 17, 1, 2, 1),
    "MOVE EA,([d16,B],d32)": row(4, 0, 16, 19, 1, 3, 1),
    "MOVE EA,([d16,B],I,d32)": row(4, 0, 16, 19, 1, 3, 1),
    "MOVE EA,([d32,B])":  row(4, 0, 16, 18, 1, 2, 1),
    "MOVE EA,([d32,B],I)": row(4, 0, 16, 18, 1, 2, 1),
    "MOVE EA,([d32,B],d16)": row(4, 0, 18, 21, 1, 3, 1),
    "MOVE EA,([d32,B],I,d16)": row(4, 0, 18, 21, 1, 3, 1),
    "MOVE EA,([d32,B],d32)": row(4, 0, 20, 23, 1, 3, 1),
    "MOVE EA,([d32,B],I,d32)": row(4, 0, 20, 23, 1, 3, 1),
}

# 11.6.7 Special-purpose MOVE, p. 11-39.  CR-A = USP, VBR, CAAR, MSP, ISP;
# CR-B = SFC, DFC, CACR.  MOVEM: n registers, w wait states - I-cache case
# EA,RL = 8+4n (w <= 2), 8+4n+(w-2)n (w > 2), tail 0; RL,EA = 4+2n+(n-1)w
# (w <= 2), 4+2n+(n-1)w+(w-2) (w > 2), tail (n-1)w or nw+n(w-2)
SPECIAL_MOVE = {
    "EXG Ry,Rx":          row(4, 0, 4, 4, 0, 1, 0),
    "MOVEC Cr,Rn":        row(6, 0, 6, 6, 0, 1, 0),
    "MOVEC Rn,Cr-A":      row(6, 0, 6, 6, 0, 1, 0),
    "MOVEC Rn,Cr-B":      row(4, 0, 12, 12, 0, 1, 0),
    "MOVE CCR,Dn":        row(2, 0, 4, 4, 0, 1, 0),
    "MOVE CCR,Mem":       row(2, 0, 4, 5, 0, 1, 1),      # * + cea
    "MOVE Dn,CCR":        row(4, 0, 4, 4, 0, 1, 0),
    "MOVE EA,CCR":        row(0, 0, 4, 4, 0, 1, 0),      # * + cea
    "MOVE SR,Dn":         row(2, 0, 4, 4, 0, 1, 0),
    "MOVE SR,Mem":        row(2, 0, 4, 5, 0, 1, 1),      # * + cea
    "MOVE EA,SR":         row(0, 0, 8, 10, 0, 2, 0),     # # + fea
    "MOVEM EA,RL":        row(2, 0, 8, 8, 0, 1, 0),      # % + ciea; + 4n, n reads (see above)
    "MOVEM RL,EA":        row(2, 0, 4, 4, 0, 1, 0),      # % + ciea; + 2n, n writes
    "MOVEP.W Dn,(d16,An)": row(4, 0, 10, 10, 0, 1, 2),
    "MOVEP.W (d16,An),Dn": row(2, 0, 10, 10, 2, 1, 0),
    "MOVEP.L Dn,(d16,An)": row(4, 0, 14, 14, 0, 1, 4),
    "MOVEP.L (d16,An),Dn": row(2, 0, 14, 14, 4, 1, 0),
    "MOVES EA,Rn":        row(3, 0, 7, 7, 1, 1, 0),      # % + ciea
    "MOVES Rn,EA":        row(2, 1, 5, 6, 0, 1, 1),      # % + ciea
    "MOVE USP,An":        row(4, 0, 4, 4, 0, 1, 0),
    "MOVE An,USP":        row(4, 0, 4, 4, 0, 1, 0),
    "SWAP Dn":            row(4, 0, 4, 4, 0, 1, 0),
}

# 11.6.8 Arithmetical/logical, pp. 11-40, 11-41 ("+": the maximum, data dependent)
ARITH = {
    "ADD Rn,Dn":          row(2, 0, 2, 2, 0, 1, 0),
    "ADDA.W Rn,An":       row(4, 0, 4, 4, 0, 1, 0),
    "ADDA.L Rn,An":       row(2, 0, 2, 2, 0, 1, 0),
    "ADD EA,Dn":          row(0, 0, 2, 2, 0, 1, 0),      # *
    "ADDA.W EA,An":       row(0, 0, 4, 4, 0, 1, 0),      # *
    "ADDA.L EA,An":       row(0, 0, 2, 2, 0, 1, 0),      # *
    "ADD Dn,EA":          row(0, 1, 3, 4, 0, 1, 1),      # *
    "AND Dn,Dn":          row(2, 0, 2, 2, 0, 1, 0),
    "AND EA,Dn":          row(0, 0, 2, 2, 0, 1, 0),      # *
    "AND Dn,EA":          row(0, 1, 3, 4, 0, 1, 1),      # *
    "EOR Dn,Dn":          row(2, 0, 2, 2, 0, 1, 0),
    "EOR Dn,EA":          row(0, 1, 3, 4, 0, 1, 1),      # *
    "OR Dn,Dn":           row(2, 0, 2, 2, 0, 1, 0),
    "OR EA,Dn":           row(0, 0, 2, 2, 0, 1, 0),      # *
    "OR Dn,EA":           row(0, 1, 3, 4, 0, 1, 1),      # *
    "SUB Rn,Dn":          row(2, 0, 2, 2, 0, 1, 0),
    "SUB EA,Dn":          row(0, 0, 2, 2, 0, 1, 0),      # *
    "SUB Dn,EA":          row(0, 1, 3, 4, 0, 1, 1),      # *
    "SUBA.W Rn,An":       row(4, 0, 4, 4, 0, 1, 0),
    "SUBA.L Rn,An":       row(2, 0, 2, 2, 0, 1, 0),
    "SUBA.W EA,An":       row(0, 0, 4, 4, 0, 1, 0),      # *
    "SUBA.L EA,An":       row(0, 0, 2, 2, 0, 1, 0),      # *
    "CMP Rn,Dn":          row(2, 0, 2, 2, 0, 1, 0),
    "CMP EA,Dn":          row(0, 0, 2, 2, 0, 1, 0),      # *
    "CMPA Rn,An":         row(4, 0, 4, 4, 0, 1, 0),
    "CMPA EA,An":         row(0, 0, 4, 4, 0, 1, 0),      # *
    "CMP2 EA,Rn":         row(2, 0, 20, 20, 1, 1, 0),    # ** + fiea, maximum
    "MULS.W EA,Dn":       row(2, 0, 28, 28, 0, 1, 0),    # * maximum
    "MULS.L EA,Dn":       row(2, 0, 44, 44, 0, 1, 0),    # ** maximum
    "MULU.W EA,Dn":       row(2, 0, 28, 28, 0, 1, 0),    # * maximum
    "MULU.L EA,Dn":       row(2, 0, 44, 44, 0, 1, 0),    # ** maximum
    "DIVS.W Dn,Dn":       row(2, 0, 56, 56, 0, 1, 0),    # maximum
    "DIVS.W EA,Dn":       row(0, 0, 56, 56, 0, 1, 0),    # * maximum
    "DIVS.L Dn,Dn":       row(6, 0, 90, 90, 0, 1, 0),    # ** maximum
    "DIVS.L EA,Dn":       row(0, 0, 90, 90, 0, 1, 0),    # ** maximum
    "DIVU.W Dn,Dn":       row(2, 0, 44, 44, 0, 1, 0),    # maximum
    "DIVU.W EA,Dn":       row(0, 0, 44, 44, 0, 1, 0),    # * maximum
    "DIVU.L Dn,Dn":       row(6, 0, 78, 78, 0, 1, 0),    # ** maximum
    "DIVU.L EA,Dn":       row(0, 0, 78, 78, 0, 1, 0),    # ** maximum
}

# 11.6.9 Immediate arithmetical/logical, p. 11-42 (* + fea, ** + fiea)
IMMED = {
    "MOVEQ #,Dn":         row(2, 0, 2, 2, 0, 1, 0),
    "ADDQ #,Rn":          row(2, 0, 2, 2, 0, 1, 0),
    "ADDQ #,Mem":         row(0, 1, 3, 4, 0, 1, 1),      # *
    "SUBQ #,Rn":          row(2, 0, 2, 2, 0, 1, 0),
    "SUBQ #,Mem":         row(0, 1, 3, 4, 0, 1, 1),      # *
    "ADDI #,Dn":          row(2, 0, 2, 2, 0, 1, 0),      # **
    "ADDI #,Mem":         row(0, 1, 3, 4, 0, 1, 1),      # **
    "ANDI #,Dn":          row(2, 0, 2, 2, 0, 1, 0),      # **
    "ANDI #,Mem":         row(0, 1, 3, 4, 0, 1, 1),      # **
    "EORI #,Dn":          row(2, 0, 2, 2, 0, 1, 0),      # **
    "EORI #,Mem":         row(0, 1, 3, 4, 0, 1, 1),      # **
    "ORI #,Dn":           row(2, 0, 2, 2, 0, 1, 0),      # **
    "ORI #,Mem":          row(0, 1, 3, 4, 0, 1, 1),      # **
    "SUBI #,Dn":          row(2, 0, 2, 2, 0, 1, 0),      # **
    "SUBI #,Mem":         row(0, 1, 3, 4, 0, 1, 1),      # **
    "CMPI #,Dn":          row(2, 0, 2, 2, 0, 1, 0),      # **
    "CMPI #,Mem":         row(0, 0, 2, 2, 0, 1, 0),      # **
}

# 11.6.10 Binary-coded decimal and extended, p. 11-43
BCD = {
    "ABCD Dn,Dn":         row(0, 0, 4, 4, 0, 1, 0),
    "ABCD -(An),-(An)":   row(2, 1, 13, 14, 2, 1, 1),
    "SBCD Dn,Dn":         row(0, 0, 4, 4, 0, 1, 0),
    "SBCD -(An),-(An)":   row(2, 1, 13, 14, 2, 1, 1),
    "ADDX Dn,Dn":         row(2, 0, 2, 2, 0, 1, 0),
    "ADDX -(An),-(An)":   row(2, 1, 9, 10, 2, 1, 1),
    "SUBX Dn,Dn":         row(2, 0, 2, 2, 0, 1, 0),
    "SUBX -(An),-(An)":   row(2, 1, 9, 10, 2, 1, 1),
    "CMPM (An)+,(An)+":   row(0, 0, 8, 8, 2, 1, 0),
    "PACK Dn,Dn,#":       row(6, 0, 6, 6, 0, 1, 0),
    "PACK -(An),-(An),#": row(2, 1, 11, 11, 1, 1, 1),
    "UNPK Dn,Dn,#":       row(8, 0, 8, 8, 0, 1, 0),
    "UNPK -(An),-(An),#": row(2, 1, 11, 11, 1, 1, 1),
}

# 11.6.11 Single operand, p. 11-44 (* + fea, ** + cea)
SINGLE = {
    "CLR Dn":             row(2, 0, 2, 2, 0, 1, 0),
    "CLR Mem":            row(0, 1, 3, 4, 0, 1, 1),      # **
    "NEG Dn":             row(2, 0, 2, 2, 0, 1, 0),
    "NEG Mem":            row(0, 1, 3, 4, 0, 1, 1),      # *
    "NEGX Dn":            row(2, 0, 2, 2, 0, 1, 0),
    "NEGX Mem":           row(0, 1, 3, 4, 0, 1, 1),      # *
    "NOT Dn":             row(2, 0, 2, 2, 0, 1, 0),
    "NOT Mem":            row(0, 1, 3, 4, 0, 1, 1),      # *
    "EXT Dn":             row(4, 0, 4, 4, 0, 1, 0),
    "NBCD Dn":            row(0, 0, 6, 6, 0, 1, 0),
    "Scc Dn":             row(4, 0, 4, 4, 0, 1, 0),
    "Scc Mem":            row(0, 1, 5, 5, 0, 1, 1),      # **
    "TAS Dn":             row(4, 0, 4, 4, 0, 1, 0),
    "TAS Mem":            row(3, 0, 12, 12, 1, 1, 1),    # **
    "TST Dn":             row(0, 0, 2, 2, 0, 1, 0),
    "TST Mem":            row(0, 0, 2, 2, 0, 1, 0),      # *
}

# 11.6.12 Shift/rotate, p. 11-45 (% count <= the size, + count > the size;
# the count does not otherwise matter)
SHIFT = {
    "LSd #,Dy":           row(4, 0, 4, 4, 0, 1, 0),
    "LSd Dx,Dy":          row(6, 0, 6, 6, 0, 1, 0),      # %
    "LSd Dx,Dy +":        row(8, 0, 8, 8, 0, 1, 0),      # +
    "LSd Mem":            row(0, 0, 4, 4, 0, 1, 1),      # * by 1
    "ASL #,Dy":           row(2, 0, 6, 6, 0, 1, 0),
    "ASL Dx,Dy":          row(4, 0, 8, 8, 0, 1, 0),
    "ASL Mem":            row(0, 0, 6, 6, 0, 1, 1),      # *
    "ASR #,Dy":           row(4, 0, 4, 4, 0, 1, 0),
    "ASR Dx,Dy":          row(6, 0, 6, 6, 0, 1, 0),      # %
    "ASR Dx,Dy +":        row(10, 0, 10, 10, 0, 1, 0),   # +
    "ASR Mem":            row(0, 0, 4, 4, 0, 1, 1),      # *
    "ROd #,Dy":           row(4, 0, 6, 6, 0, 1, 0),
    "ROd Dx,Dy":          row(6, 0, 8, 8, 0, 1, 0),
    "ROd Mem":            row(0, 0, 6, 6, 0, 1, 1),      # *
    "ROXd Dn":            row(10, 0, 12, 12, 0, 1, 0),
    "ROXd Mem":           row(0, 0, 4, 4, 0, 1, 0),      # *
}

# 11.6.13 Bit manipulation, p. 11-46 (* + fea, # + fiea)
BIT = {
    "BTST #,Dn":          row(4, 0, 4, 4, 0, 1, 0),
    "BTST Dn,Dn":         row(4, 0, 4, 4, 0, 1, 0),
    "BTST #,Mem":         row(0, 0, 4, 4, 0, 1, 0),      # #
    "BTST Dn,Mem":        row(0, 0, 4, 4, 0, 1, 0),      # *
    "BCHG #,Dn":          row(6, 0, 6, 6, 0, 1, 0),
    "BCHG Dn,Dn":         row(6, 0, 6, 6, 0, 1, 0),
    "BCHG #,Mem":         row(0, 0, 6, 6, 0, 1, 1),      # #
    "BCHG Dn,Mem":        row(0, 0, 6, 6, 0, 1, 1),      # *
    "BCLR #,Dn":          row(6, 0, 6, 6, 0, 1, 0),
    "BCLR Dn,Dn":         row(6, 0, 6, 6, 0, 1, 0),
    "BCLR #,Mem":         row(0, 0, 6, 6, 0, 1, 1),      # #
    "BCLR Dn,Mem":        row(0, 0, 6, 6, 0, 1, 1),      # *
    "BSET #,Dn":          row(6, 0, 6, 6, 0, 1, 0),
    "BSET Dn,Dn":         row(6, 0, 6, 6, 0, 1, 0),
    "BSET #,Mem":         row(0, 0, 6, 6, 0, 1, 1),      # #
    "BSET Dn,Mem":        row(0, 0, 6, 6, 0, 1, 1),      # *
}

# 11.6.14 Bit field, p. 11-47 (* + ciea; a 32-bit field over 5 bytes takes two operand cycles)
BITFIELD = {
    "BFTST Dn":           row(8, 0, 8, 8, 0, 1, 0),
    "BFTST Mem<5":        row(6, 0, 10, 10, 1, 1, 0),
    "BFTST Mem5":         row(6, 0, 14, 14, 2, 1, 0),
    "BFCHG Dn":           row(14, 0, 14, 14, 0, 1, 0),
    "BFCHG Mem<5":        row(6, 0, 14, 14, 1, 1, 1),
    "BFCHG Mem5":         row(6, 0, 22, 22, 2, 1, 2),
    "BFCLR Dn":           row(14, 0, 14, 14, 0, 1, 0),
    "BFCLR Mem<5":        row(6, 0, 14, 14, 1, 1, 1),
    "BFCLR Mem5":         row(6, 0, 22, 22, 2, 1, 2),
    "BFSET Dn":           row(14, 0, 14, 14, 0, 1, 0),
    "BFSET Mem<5":        row(6, 0, 14, 14, 1, 1, 1),
    "BFSET Mem5":         row(6, 0, 22, 22, 2, 1, 2),
    "BFEXTS Dn":          row(10, 0, 10, 10, 0, 1, 0),
    "BFEXTS Mem<5":       row(6, 0, 12, 12, 1, 1, 0),
    "BFEXTS Mem5":        row(6, 0, 18, 18, 2, 1, 0),
    "BFEXTU Dn":          row(10, 0, 10, 10, 0, 1, 0),
    "BFEXTU Mem<5":       row(6, 0, 12, 12, 1, 1, 0),
    "BFEXTU Mem5":        row(6, 0, 18, 18, 2, 1, 0),
    "BFINS Dn":           row(12, 0, 12, 12, 0, 1, 0),
    "BFINS Mem<5":        row(6, 0, 12, 12, 1, 1, 1),
    "BFINS Mem5":         row(6, 0, 18, 18, 2, 1, 2),
    "BFFFO Dn":           row(20, 0, 20, 20, 0, 1, 0),
    "BFFFO Mem<5":        row(6, 0, 22, 22, 1, 1, 0),
    "BFFFO Mem5":         row(6, 0, 28, 28, 2, 1, 0),
}

# 11.6.15 Conditional branch, p. 11-48 (complete times)
BRANCH = {
    "Bcc taken":          row(6, 0, 6, 8, 0, 2, 0),
    "Bcc.B not taken":    row(4, 0, 4, 4, 0, 1, 0),
    "Bcc.W not taken":    row(6, 0, 6, 6, 0, 1, 0),
    "Bcc.L not taken":    row(6, 0, 6, 8, 0, 2, 0),
    "DBcc loop":          row(6, 0, 6, 8, 0, 2, 0),      # cc false, count not expired
    "DBcc expired":       row(10, 0, 10, 13, 0, 3, 0),   # cc false, count expired
    "DBcc true":          row(6, 0, 6, 8, 0, 1, 0),
}

# 11.6.16 Control, p. 11-49 (* + fea, ** + cea, # + fiea, ## + ciea, % + jea; + maximum)
CONTROL = {
    "ANDI to SR":         row(4, 0, 12, 14, 0, 2, 0),
    "EORI to SR":         row(4, 0, 12, 14, 0, 2, 0),
    "ORI to SR":          row(4, 0, 12, 14, 0, 2, 0),
    "ANDI to CCR":        row(4, 0, 12, 14, 0, 2, 0),
    "EORI to CCR":        row(4, 0, 12, 14, 0, 2, 0),
    "ORI to CCR":         row(4, 0, 12, 14, 0, 2, 0),
    "BSR":                row(2, 0, 6, 9, 0, 2, 1),
    "CAS success":        row(1, 0, 13, 13, 1, 1, 1),    # ##
    "CAS fail":           row(1, 0, 11, 11, 1, 1, 0),    # ##
    "CAS2 success":       row(2, 0, 24, 26, 2, 2, 2),    # +
    "CAS2 fail":          row(2, 0, 24, 24, 2, 2, 0),    # +
    "CHK Dn,Dn":          row(8, 0, 8, 8, 0, 1, 0),
    "CHK Dn,Dn trap":     row(4, 0, 28, 30, 1, 3, 4),    # +
    "CHK EA,Dn":          row(0, 0, 8, 8, 0, 1, 0),      # *
    "CHK EA,Dn trap":     row(0, 0, 28, 30, 1, 3, 4),    # * +
    "CHK2 Mem,Rn":        row(2, 0, 18, 18, 1, 1, 0),    # # +
    "CHK2 Mem,Rn trap":   row(2, 0, 40, 42, 2, 3, 4),    # # +
    "JMP":                row(4, 0, 4, 6, 0, 2, 0),      # % + jea
    "JSR":                row(0, 0, 4, 7, 0, 2, 1),      # % + jea
    "LEA":                row(2, 0, 2, 2, 0, 1, 0),      # ** + cea
    "LINK.W":             row(0, 0, 4, 5, 0, 1, 1),
    "LINK.L":             row(2, 0, 6, 7, 0, 2, 1),
    "NOP":                row(0, 0, 2, 2, 0, 1, 0),
    "PEA":                row(0, 2, 4, 4, 0, 1, 1),      # ** + cea
    "RTD":                row(2, 0, 10, 12, 1, 2, 0),
    "RTR":                row(1, 0, 12, 14, 2, 2, 0),
    "RTS":                row(1, 0, 9, 11, 1, 2, 0),
    "UNLK":               row(0, 0, 5, 5, 1, 1, 0),
}

# 11.6.17 Exception-related, p. 11-50
EXCEPTION = {
    "BKPT":               row(1, 0, 9, 9, 1, 0, 0),
    "Interrupt I-stack":  row(0, 0, 23, 24, 2, 2, 4),
    "Interrupt M-stack":  row(0, 0, 33, 34, 2, 2, 8),
    "RESET instruction":  row(0, 0, 518, 518, 0, 1, 0),
    "STOP":               row(0, 0, 8, 8, 0, 2, 0),
    "TRACE":              row(0, 0, 22, 24, 1, 2, 5),
    "TRAP #n":            row(0, 0, 18, 20, 1, 2, 4),
    "Illegal instruction": row(0, 0, 18, 20, 1, 2, 4),
    "A-line trap":        row(0, 0, 18, 20, 1, 2, 4),
    "F-line trap":        row(0, 0, 18, 20, 1, 2, 4),
    "Privilege violation": row(0, 0, 18, 20, 1, 2, 4),
    "TRAPcc trap":        row(2, 0, 22, 24, 1, 2, 5),
    "TRAPcc no trap":     row(4, 0, 4, 4, 0, 1, 0),
    "TRAPcc.W trap":      row(5, 0, 24, 26, 1, 3, 5),
    "TRAPcc.W no trap":   row(6, 0, 6, 6, 0, 1, 0),
    "TRAPcc.L trap":      row(6, 0, 26, 28, 1, 3, 5),
    "TRAPcc.L no trap":   row(8, 0, 8, 8, 0, 2, 0),
    "TRAPV trap":         row(2, 0, 22, 24, 1, 2, 5),
    "TRAPV no trap":      row(4, 0, 4, 4, 0, 1, 0),
}

# 11.6.18 Save and restore, p. 11-51
SAVE_RESTORE = {
    "Bus fault short":    row(0, 0, 36, 38, 1, 2, 10),
    "Bus fault long":     row(0, 0, 62, 64, 1, 2, 24),
    "RTE four word":      row(1, 0, 18, 20, 4, 2, 0),
    "RTE six word":       row(1, 0, 18, 20, 4, 2, 0),
    "RTE throwaway":      row(1, 0, 12, 12, 4, 0, 0),
    "RTE coprocessor":    row(1, 0, 26, 26, 7, 2, 0),
    "RTE short fault":    row(1, 0, 36, 26, 10, 2, 0),  # as printed (the no-cache figure is lower)
    "RTE long fault":     row(1, 0, 76, 76, 25, 2, 0),
}

TABLES = dict(FEA=FEA, FIEA=FIEA, CEA=CEA, CIEA=CIEA, JEA=JEA, MOVE=MOVE, SPECIAL_MOVE=SPECIAL_MOVE,
              ARITH=ARITH, IMMED=IMMED, BCD=BCD, SINGLE=SINGLE, SHIFT=SHIFT, BIT=BIT, BITFIELD=BITFIELD,
              BRANCH=BRANCH, CONTROL=CONTROL, EXCEPTION=EXCEPTION, SAVE_RESTORE=SAVE_RESTORE)

if __name__ == "__main__":
    for name, t in TABLES.items():
        print("%-13s %3d rows" % (name, len(t)))
