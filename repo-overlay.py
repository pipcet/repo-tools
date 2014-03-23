import subprocess
import pygit2
import argparse
import os
import shutil

from string import hexdigits
from collections import deque
from stat import *

parser = argparse.ArgumentParser(description='')

parser.add_argument('--hardlink', action='store_true')
parser.add_argument('--out')
parser.add_argument('--in')
parser.add_argument('--new-versions', action='store_true')
parser.add_argument('--new-symlinks', action='store_true')
parser.add_argument('--apply')
parser.add_argument('--apply-repo')
parser.add_argument('--apply-use-manifest')

args = parser.parse_args()

args.new_versions = True
xxxpwd = os.getcwd()

def symlink_relative(target, directory, name):
    try:
        makepath(directory)
    except OSError:
        pass
    relpath = os.path.relpath(target, directory)
    try:
        os.symlink(relpath, os.path.join(directory, name))
    except OSError:
        pass

def symlink_absolute(target, directory, name):
    try:
        makepath(directory)
    except OSError:
        pass
    try:
        os.symlink(target, os.path.join(directory, name))
    except OSError:
        pass

def copy_or_hardlink(target, directory, name):
    try:
        makepath(directory)
    except OSError:
        pass
    shutil.copy2(target, os.path.join(directory, name))

def makepath(path):
    try:
        os.makedirs(path)
    except:
        pass

class RoRepository:
    def master(self):
        path = xxxoutdir + "/repos-by-name/" + self.name + "/repo"
        master = os.readlink(path)

        return os.path.join(os.path.dirname(path), master)

class RoGitRepository(RoRepository):
    def git(self, *args):
        proc = subprocess.Popen(["git"] + [arg for arg in args],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                cwd=self.gitpath)
        (out, err) = proc.communicate()
        return out.rstrip()

    def gitz(self, *args):
        proc = subprocess.Popen(["git"] + [arg for arg in args] + ["-z"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                cwd=self.gitpath)
        (out, err) = proc.communicate()
        res = out.split("\0")
        res.pop()
        return res

    def revparse(self, head):
        ret = self.git("rev-parse", head)

        if len(ret) < 10:
            return None
        if not all (c in hexdigits for c in ret):
            return None
        return ret

    def git_parents(self, commit):
        i = 1
        res = []
        while True:
            p = self.revparse(commit + "^" + str(i))
            if p is None:
                break
            res.append(p)
            i = i + 1

        return res

    def head(self):
        branch = self.git("log", "-1", "--first-parent", "--reverse", "--pretty=tformat:%H", "--until=" + self.date)
        branch = branch[0:40]

        if args.new_versions:
            head = self.revparse(branch)
        else:
            head = self.version

        if head is None:
            head = "HEAD"

        oldhead = head
        newhead = head

        self.oldhead = oldhead
        self.newhead = newhead

        return head

    @property
    def pygit2tree(self):
        if self._pygit2tree is None:
            r = self.pygit2repository
            head = r.head.target
            while isinstance(head, pygit2.Reference):
                head = head.target

            self._pygit2tree = r.get(head).tree
        return self._pygit2tree

    @property
    def pygit2repository(self):
        if self._pygit2repository is None:
            self._pygit2repository = pygit2.Repository(self.gitpath)

        return self._pygit2repository

    def __init__(self, path, name, url, gitpath, date, version):
        self.relpath = path
        self.name = name
        self.url = url
        self.gitpath = gitpath
        self.date = date
        self.version = version

        self._pygit2tree = None
        self._pygit2repository = None

class RoGitRepositoryHead(RoGitRepository):
    def find_changed(self, dirstate):
        res = []
        if not self.master().startswith(xxxpwd + "/"):
            res.append(os.dirname(self.relpath))

        print self.relpath
        l = deque(self.gitz("diff", self.head(), "--name-status"))
        while len(l) > 0:
            stat = l.popleft()
            path = l.popleft()

            res.append(os.path.join(self.relpath, path))

        if self.oldhead == self.newhead:
            return res

        l = deque(self.gitz("diff", self.oldhead + ".." + self.newhead, "--name-status"))
        while len(l) > 0:
            stat = l.popleft()
            path = l.popleft()

            res.append(os.path.join(self.relpath, path))

        return res

    def find_siblings_and_types(self, dirstate, path="", tree=None):
        if tree is None:
            tree = self.pygit2tree

        res = []

        for entry in tree:
            filemode = "{0:06o}".format(entry.filemode)
            filemode = filemode[0:3]
            itempath = os.path.join(path, entry.name)
            if filemode == "040":
                res += [[itempath, "dir"]]
                if dirstate.changed(os.path.join(self.relpath, itempath)):
                    res += self.find_siblings_and_types(dirstate, itempath, self.pygit2repository[entry.id])
            elif filemode == "120":
                res += [[itempath, "link"]]
            elif filemode == "100":
                res += [[itempath, "file"]]
            else:
                raise Error()

        return res

    def create_file(self, file, dst):
        makepath(os.path.dirname(dst))
        tree = self.pygit2tree
        oid = tree[file].id
        blob = self.pygit2repository[oid]

        os.system("rm " + dst)
        f = open(dst, 'wb')
        f.write(blob.data)

    def create_link(self, file, dst):
        makepath(os.path.dirname(dst))

        tree = self.pygit2tree
        oid = tree[file].id
        blob = self.pygit2repository[oid]

        os.system("rm " + dst)
        symlink_absolute(blob.data, os.path.dirname(dst), os.path.basename(dst))

class RoGitRepositoryHeadNew(RoGitRepositoryHead):
    def head(self):
        head = super(RoGitRepositoryHeadNew, self).head()

        if not xxxapply is None:
            if head in self.git_parents(xxxapply):
                newhead = xxxapply
                apply_success += 1

        if not xxxdo_emancipate:
            head = newhead

        return head

class RoGitRepositoryWD(RoGitRepository):
    def find_changed(self, dirstate):
        res = []
        if not self.master().startswith(xxxpwd + "/"):
            res.append(os.dirname(self.relpath))

        l = deque(self.gitz("status"))
        while len(l) > 0:
            line = l.popleft()
            stat = line[0:2]
            path = line[3:]

            res.append(os.path.join(self.relpath, path))

        if self.oldhead == self.newhead:
            return res

        l = deque(self.gitz("diff", self.oldhead + ".." + self.newhead, "--name-status"))
        while len(l) > 0:
            stat = l.popleft()
            path = l.popleft()

            res.append(os.path.join(self.relpath, path))

        return res

    def find_siblings_and_types(self, dirstate, path=None):
        if path is None:
            path = self.relpath
        res = []
        for f in os.listdir(os.path.join(xxxpwd, path)):
            fullpath = os.path.join(xxxpwd, path, f)
            if f in self.mdata.repos:
                continue
            if f == ".git":
                continue
            if fullpath.startswith(os.path.join(xxxpwd, "out")):
                continue
            if os.path.islink(fullpath):
                res.append([os.path.join(path, f), "link"])
            elif os.path.isfile(fullpath):
                res.append([os.path.join(path, f), "file"])
            elif os.path.isdir(fullpath):
                res.append([os.path.join(path, f), "dir"])
                if dirstate.changed(os.path.join(path, f)):
                    res += self.find_siblings_and_types(dirstate, os.path.join(path, f))

        return res

    def create_file(self, file, dst):
        copy_or_hardlink(file, os.path.dirname(dst), os.path.basename(dst))

    def create_link(self, file, dst):
        copy_or_hardlink(file, os.path.dirname(dst), os.path.basename(dst))


class RoEmptyRepository(RoRepository):
    def find_changed(self, dirstate):
        return []

    def find_siblings_and_types(self, dirstate, path=""):
        return []

def stripprefix(string, prefix):
    if string.startswith(prefix):
        return string[len(prefix):]
    raise Error()

class ManifestData:
    def read_version(self, repo):
        try:
            f = open(xxxoutdir + "/head/.pipcet-ro/versions/" + repo + "/version.txt")
            (path,sep,info) = f.readlines()[0].partition(": ")
            (head,name,url) = info.split(" ")
        except IOError:
            return None

        return head

    def read_versions(self):
        for dirpath, dirs, files in os.walk(xxxoutdir + "/head/.pipcet-ro/versions"):
            if "version.txt" in files:
                f = open(os.path.join(dirpath, "version.txt"))
                (path,info) = f.readlines()[0].partition(": ")
                (head,name,url) = info.split(" ")

                self.version[path] = head

    def find_repository(self, path):
        while path != "":
            try:
                r = self.repos[path]
                return (r, path)
            except KeyError:
                pass

            path = os.path.dirname(path)

        return (None, None)

    def new_repository_class(self):
        return RoGitRepositoryHead

    def new_repository(self, repopath, name, url, gitpath, date, version):
        self.repos[repopath] = self.new_repository_class()(repopath, name, url, gitpath, date, version)
    def __init__(self, version=None, date=None):
        self.version = {}
        self.repos = {}

        self.date = date

        if not version is None:
            cmd = "echo rm -rf {outdir}/manifests; mkdir -p {outdir}/manifests/{version}/manifests && cp -a {pwd}/.repo/local_manifests {outdir}/manifests/{version}/ && git clone {pwd}/.repo/manifests {outdir}/manifests/{version}/manifests && (cd {outdir}/manifests/{version}/manifests && git checkout {version} && cp -a .git ../manifests.git && ln -s manifests/default.xml ../manifest.xml && git config remote.origin.url git://github.com/Quarx2k/android.git) && (cd {pwd}; python {pwd}/.repo/repo/main.py --wrapper-version=1.21 --repo-dir={outdir}/manifests/{version} -- list --url > {outdir}/manifests/{version}/output)"
            os.system(cmd.format(pwd=xxxpwd, outdir=xxxoutdir, version=version))

            for line in open(os.path.join(xxxoutdir, "manifests", version, "output")).readlines():
                (repopath,name,url,branchref) = line.split(" : ")
                self.new_repository(repopath, name, url, os.path.join(xxxoutdir, "repos-by-name", name, "repo"), date, self.read_version(repopath))

        repopath = ".repo/repo"
        self.new_repository(repopath, repopath, "", os.path.join(xxxoutdir, "repos-by-name", repopath, "repo"), date, self.read_version(repopath))

        repopath = ".repo/manifests"
        self.new_repository(repopath, repopath, "", os.path.join(xxxoutdir, "repos-by-name", repopath, "repo"), date, self.read_version(repopath))

        self.repos[""] = RoEmptyRepository()

class ManifestDataHead(ManifestData):
    def new_repository_class(self):
        return RoGitRepositoryHead

class ManifestDataHeadNew(ManifestDataHead):
    def new_repository_class(self):
        return RoGitRepositoryHeadNew

class ManifestDataWD(ManifestData):
    def new_repository_class(self):
        return RoGitRepositoryWD

    def __init__(self, version=None, date=None):
        self.version = {}
        self.repos = {}

        self.date = date

        if not version is None:
            cmd = "echo rm -rf {outdir}/manifests; mkdir -p {outdir}/manifests/{version}/manifests && cp -a {pwd}/.repo/local_manifests {outdir}/manifests/{version}/ && git clone {pwd}/.repo/manifests {outdir}/manifests/{version}/manifests && (cd {outdir}/manifests/{version}/manifests && git checkout {version} && cp -a .git ../manifests.git && ln -s manifests/default.xml ../manifest.xml && git config remote.origin.url git://github.com/Quarx2k/android.git) && (cd {pwd}; python {pwd}/.repo/repo/main.py --wrapper-version=1.21 --repo-dir={outdir}/manifests/{version} -- list --url > {outdir}/manifests/{version}/output)"
            os.system(cmd.format(pwd=xxxpwd, outdir=xxxoutdir, version=version))

            for line in open(os.path.join(xxxoutdir, "manifests", version, "output")).readlines():
                (repopath,name,url,branchref) = line.split(" : ")
                self.new_repository(repopath, name, url, os.path.join(xxxoutdir, "repos-by-name", name, "repo"), date, self.read_version(repopath))
        else:
            pass

        repopath = ".repo/repo"
        self.new_repository(repopath, repopath, "", os.path.join(xxxoutdir, "repos-by-name", repopath, "repo"), date, self.read_version(repopath))

        repopath = ".repo/manifests"
        self.new_repository(repopath, repopath, "", os.path.join(xxxoutdir, "repos-by-name", repopath, "repo"), date, self.read_version(repopath))

        self.repos[""] = RoEmptyRepository()



class Item:
    def __init__(self, path, itemtype=None, changed=None):
        self.path = path
        self.itemtype = itemtype
        self.changed = changed
        self.masterpath = None
        self.gitpath = None
        self.repo = None
        self.r = None
        self.repopath = None

    def create(self, dirstate, outdir):
        gitpath = self.gitpath
        repo = self.repo
        r = self.r
        path = self.repopath
        itemtype = self.itemtype

        if itemtype == "dir":
            dirname = path
            while not dirstate.changed(dirname):
                (path, dirname) = (dirname, os.path.dirname(dirname))

            if dirstate.changed(path):
                try:
                    makepath(os.path.join(outdir, path))
                except OSError:
                    pass
            else:
                if not os.path.lexists(os.path.join(outdir, path)):
                    symlink_relative(xxxpwd + "/" + path, outdir, path)
        elif itemtype == "file":
            if self.changed:
                r.create_file(gitpath, outdir + "/" + repo + "/" + gitpath)
            else:
                symlink_relative(os.path.join(r.master(), gitpath), os.path.dirname(os.path.join(outdir, repo, gitpath)), os.path.basename(gitpath))
        elif itemtype == "link":
            r.create_link(gitpath, outdir + "/" + repo + "/" + gitpath)

class DirState:
    def create_directory(self, outdir):
        for item in self.items:
            self.items[item].create(self, outdir)

    def snapshot(self, outdir, *arg_repos):
        repos = arg_repos
        if len(repos) == 0:
            repos = self.mdata.repos.keys()

            os.system("echo rm -rf " + outdir + "/*")
            os.system("echo rm -rf " + outdir + "/.repo")
            try:
                makepath(outdir)
            except OSError:
                pass

        changed = []
        for repo in self.mdata.repos:
            changed += self.mdata.repos[repo].find_changed(self)
        for path in changed:
            self.store_item(path, Item(path, changed=1))

        types = []
        for repo in self.mdata.repos:
            types += self.mdata.repos[repo].find_siblings_and_types(self, repo)
        for path, itemtype in types:
            self.store_item(path, Item(path, itemtype=itemtype))

        self.create_directory(outdir)


    def changed(self, path):
        try:
            return self.items[path].changed
        except KeyError:
            return False

    def store_item(self, path, item):
        (item.r, item.repo) = self.mdata.find_repository(path)

        if not item.r is None:
            item.gitpath = os.path.relpath(path, item.repo)

            if item.masterpath is None:
                item.master = item.r.master()
                item.masterpath = item.master + "/" + item.gitpath

        item.repopath = path

        if path in self.items:
            olditem = self.items[path]
        else:
            olditem = Item(path)
            self.items[path] = olditem

        for key in item.__dict__:
            if not item.__dict__[key] is None:
                olditem.__dict__[key] = item.__dict__[key]

        if path == "":
            return

        directory = os.path.dirname(path)
        if not directory in self.items:
            return

        diritem = Item(directory)
        diritem.itemtype = "dir"
        if item.changed:
            diritem.changed = True


        self.store_item(directory, diritem)

    def directory_changed(self, path):
        return self.changed(os.dirname(path))

    def __init__(self, mdata):
        self.items = {"": Item("", changed=True)}
        self.mdata = mdata

def path_prefixes(path):
    res = []
    while path != "":
        path = os.path.dirname(path)
        res.append(path)
    return res.reverse()

def delete_repository(outdir, repo):
    prefixes = path_prefixes(repo)

    for prefix in prefixes:
        if os.path.islink(os.path.join(outdir, prefix)):
            os.system("echo rm " + os.path.join(outdir, prefix))
            return

    if os.path.islink(os.path.join(outdir, repo)):
        os.system("echo rm " + os.path.join(outdir, repo))
    else:
        os.system("echo rm -r " + os.path.join(outdir, repo))

def setup_repo_links():
    os.system("echo rm -rf " + xxxoutdir + "/repos-by-name")

    head_mdata = ManifestDataHeadNew(version = "HEAD")

    for repo in head_mdata.repos:
        r = head_mdata.repos[repo]
        if isinstance(r, RoEmptyRepository):
            continue

        name = r.name
        linkdir = os.path.join(xxxoutdir, "repos-by-name", name)
        symlink_absolute(os.path.join(xxxpwd, r.relpath),
                         linkdir, "repo")

def backtick(cwd, *args):
    proc = subprocess.Popen([arg for arg in args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            cwd=cwd)
    (out, err) = proc.communicate()
    return out.rstrip()

xxxoutdir = "/home/pip/tmp-repo-overlay"

setup_repo_links()

if args.new_versions:
    os.system("echo rm -rf " + xxxoutdir + "/head/.pipcet-ro/versions/*")
    os.system("rm -rf " + xxxoutdir + "/head-py")

if args.new_versions:
    manifest_head = backtick(xxxpwd + "/.repo/manifests", "git", "log", "-1", "--first-parent", "--pretty=tformat:%H", "--until='$date")
else:
    manifest_head = ManifestData().read_version(".repo/manifests")

mdata_head = ManifestData(version=manifest_head, date="March.1")
dirstate_head = DirState(mdata_head)

dirstate_head.snapshot("/home/pip/tmp-repo-overlay/head-py")
