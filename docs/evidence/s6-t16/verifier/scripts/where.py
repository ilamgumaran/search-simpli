import subprocess,sys
sys.path.insert(0,'.')
from tokdiff_lib import toks
REPO=sys.argv[1]
def git(*a): return subprocess.run(["git","-C",REPO,*a],capture_output=True,text=True,check=True).stdout
files=[f for f in git("ls-tree","-r","--name-only","HEAD").splitlines() if f.endswith('.zig') and ('/ops/' in f or '/interfaces/' in f)]
want={('scope','visibleCollection'),('scope','View'),('scope','documentFrequency'),('scope','holdsAll'),('hybrid','isAuthorized'),('hybrid','RootMask'),('hybrid','matchesPath'),('filename_field','tokenize'),('filename_field','Hit'),('title_field','derive'),('segment','encode'),('lexical_segment','encode'),('postings','build'),('postings','TermEntry'),('postings','Posting'),('manifest','create'),('manifest','encode'),('manifest','decode'),('lifecycle','publishSerialized'),('generation_alloc','nextFreeGeneration'),('analyzer_v2','analyzer_id'),('scope','recordPath'),('scope','relativePath'),('scope','rootOfPath'),('scope','isLegacy'),('scope','legacy_root_id')}
IMP=[("b","@import"),("p","("),("s",'"core"'),("p",")"),("p","."),("w","api")]
from collections import defaultdict
where=defaultdict(set)
for f in files:
    text=git("show",f"HEAD:{f}"); t=toks(text)
    # test-block ranges by token index
    tests=[]
    for i in range(len(t)-1):
        if t[i]==("w","test") and t[i+1][0] in("s","w","p"):
            j=i
            while t[j]!=("p","{"): j+=1
            d=0;k=j
            while True:
                if t[k]==("p","{"): d+=1
                elif t[k]==("p","}"):
                    d-=1
                    if d==0: break
                k+=1
            tests.append((i,k))
    intest=lambda k:any(a<=k<=b for a,b in tests)
    aliases={}
    for i in range(len(t)):
        if t[i:i+6]==IMP:
            ch=[];j=i+6
            while t[j]==("p",".") and t[j+1][0]=="w": ch.append(t[j+1][1]); j+=2
            if t[i-3]==("w","const") and t[j]==("p",";") and len(ch)==1: aliases[t[i-2][1]]=ch[0]
            elif len(ch)>=2 and tuple(ch[:2]) in want: where[tuple(ch[:2])].add((f.split('/')[-1],'test' if intest(i) else 'code'))
    for a,ns in aliases.items():
        for k in range(1,len(t)-2):
            if t[k]==("w",a) and t[k-1]!=("p",".") and t[k+1]==("p",".") and (ns,t[k+2][1]) in want:
                where[(ns,t[k+2][1])].add((f.split('/')[-1],'test' if intest(k) else 'code'))
for k in sorted(want): print('.'.join(k), sorted(where[k]))
