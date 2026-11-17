#!/usr/bin/env python3
"""S6-T7 verifier: the five files that gave 1-byte overlaps (recipe value 1) in b.txt, c.txt and e.txt.
    k1_gen.py OUTDIR   (OUTDIR must exist; run in it as written here, seed 5)"""
import os, random, sys
os.chdir(sys.argv[1])
r = random.Random(5)
open("a.txt","w").write("".join(("\n" if r.random()<0.5 else "w"*r.randint(1,900)+"\n") for _ in range(400)))
open("b.txt","w").write("".join(("x"*r.choice([1,2,1500,1590,800])+"\n") for _ in range(300)))
open("c.txt","w").write("\n".join(["p"*1590, "", "q"*1590, "", "r"*1590, "z", "s"*1590]*20)+"\n")
open("d.md","w").write("".join(f"# H{i}\n\n" + ("t"*r.randint(1,1700)+"\n")*r.randint(1,3) for i in range(200)))
open("e.txt","w").write("".join(("y"*r.randint(0,3)+"\n") for _ in range(9000)))
