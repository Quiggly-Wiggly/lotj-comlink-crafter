"""Verify release contents, reproducibility, Lua syntax, and behavior."""
from pathlib import Path
import importlib.util, os, shutil, subprocess, tempfile, unittest, re, xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('builder',ROOT/'scripts/build.py')
builder=importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
def lua():
    if os.environ.get('LUA'):
        p=os.environ['LUA']; return [p]+(['--luaonly'] if 'tex' in Path(p).name else [])
    for name in ('luajit','lua5.1','lua'):
        if shutil.which(name): return [shutil.which(name)]
    for p in sorted(Path('/usr/local/texlive').glob('*/bin/*/luajittex'),reverse=True): return [str(p),'--luaonly']
    raise RuntimeError('Install LuaJIT / Lua 5.1 or set LUA')
def run(script,*args,cwd=ROOT):
    result=subprocess.run(lua()+[str(script)]+list(map(str,args)),cwd=cwd,text=True,capture_output=True)
    if result.returncode: raise AssertionError(result.stdout+result.stderr)
    return result.stdout
class ReleaseTests(unittest.TestCase):
    def test_package(self):
        with tempfile.TemporaryDirectory() as t:
            a=builder.build(Path(t)/'a.mpackage'); b=builder.build(Path(t)/'b.mpackage')
            self.assertEqual(a.read_bytes(),b.read_bytes())
            self.assertEqual(a.read_bytes(),(ROOT/builder.ARTIFACT).read_bytes())
            files=builder.package_files()
            self.assertEqual(set(files),{builder.PACKAGE+'.xml','config.lua','README.md'})
            for name,data in files.items():
                for forbidden in (b'/Users/',b'/home/'):
                    self.assertNotIn(forbidden,data,name)
            xml=ET.fromstring(files[builder.PACKAGE+'.xml'])
            self.assertFalse(xml.findall('.//Variable'))
            paths=[]
            for i,s in enumerate(xml.iter('script')):
                if s.text:
                    p=Path(t)/f'script{i}.lua';p.write_text(s.text);paths.append(p)
            check=Path(t)/'compile.lua';check.write_text('for _,p in ipairs(arg) do assert(loadfile(p)) end\n')
            run(check,*paths)
    def exercise(self, persistence=None):
        with tempfile.TemporaryDirectory() as t:
            doc=ET.fromstring(builder.package_files()[builder.PACKAGE+'.xml'])
            core=Path(t)/'core.lua'
            core.write_text(doc.findtext('.//Script/script'))
            profile=Path(t)/'profile'; profile.mkdir()
            print(run(ROOT/'tests/behavior.lua',core,profile,persistence or ROOT/'tests/mock_persistence.lua'))

    def test_behavior(self):
        self.exercise()

    def test_installed_mudlet_persistence(self):
        resources=Path('/Applications/Mudlet.app/Contents/Resources/mudlet-lua/lua')
        if not resources.exists():
            self.skipTest('Local Mudlet persistence helpers unavailable; mock behavior checked separately')
        other=(resources/'Other.lua').read_text()
        strings=(resources/'StringUtils.lua').read_text()
        helpers=[re.search(r'^function table\.'+name+r'\(.*?^end$',other,re.M|re.S).group()
                 for name in ('save','pickle','load','unpickle')]
        helpers.append(re.search(r'^function string:enclose\(.*?^end$',strings,re.M|re.S).group())
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'persistence.lua'; p.write_text('\n'.join(helpers))
            self.exercise(p)

    def test_aliases_and_completion_messages(self):
        doc=ET.fromstring(builder.package_files()[builder.PACKAGE+'.xml'])
        aliases=doc.findall('.//Alias')
        self.assertEqual(len(aliases),10)
        for name in ('mcladd','mclremove','mclcontainer','mcliterations','mcllist','mclclear',
                     'mclstart','mclstop','mclstatus','mclhelp'):
            matching=[node for node in aliases if re.fullmatch(node.findtext('regex'),name.upper())]
            self.assertEqual(len(matching),1,name)
            self.assertIn('LotJComlink.dispatch("'+name+'"',matching[0].findtext('script'))
        triggers=doc.findall('.//Trigger')
        self.assertEqual(len(triggers),2)
        for kind in ('comlink','container'):
            line='You finish your work and hold up your newly created '+kind+'.'
            self.assertEqual(sum(bool(re.fullmatch(n.findtext('regexCodeList/string'),line)) for n in triggers),1)
        for node in doc.iter('packageName'): self.assertEqual(node.text,'LotJComlink')
        self.assertIn('Ruusm',builder.package_files()['config.lua'].decode())
