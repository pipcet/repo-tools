import subprocess
import pygit2
import argparse
import os
import shutil
import threading
import Queue
import signal

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

def delete_old_file(name):
    if os.path.isfile(name) or os.path.islink(name):
        os.system("rm " + name)

def symlink_relative(target, directory, name):
    makepath(directory)
    relpath = os.path.relpath(target, directory)
    try:
        os.symlink(relpath, os.path.join(directory, name))
    except OSError:
        pass

def symlink_absolute(target, directory, name):
    makepath(directory)

    try:
        os.symlink(target, os.path.join(directory, name))
    except OSError:
        pass

def copy_or_hardlink(target, directory, name):
    makepath(directory)
    shutil.copy2(target, os.path.join(directory, name))

def makepath(path):
    try:
        os.makedirs(path)
    except:
        pass

class RoRepository:
    def master(self):
        try:
            path = xxxoutdir + "/repos-by-name/" + self.name + "/repo"
            master = os.readlink(path)

            return os.path.join(os.path.dirname(path), master)
        except OSError:
            return ""

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
            head = r[self.head()]
            while isinstance(head, pygit2.Reference):
                head = head.target

            self._pygit2tree = head.tree
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
        if self.master() == "":
            return res

        if not self.master().startswith(xxxpwd + "/"):
            res.append(os.path.dirname(self.relpath))

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

    def find_siblings_and_types(self, dirstate, path=None, tree=None):
        if self.master() == "":
            return []

        if tree is None:
            tree = self.pygit2tree

        if path is None:
            path = self.relpath

        res = []

        for entry in tree:
            filemode = "{0:06o}".format(entry.filemode)
            filemode = filemode[0:3]
            itempath = os.path.join(path, entry.name)
            if filemode == "040":
                res += [[itempath, "dir"]]
                if dirstate.changed(itempath):
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

        delete_old_file(dst)
        f = open(dst, 'wb')
        f.write(blob.data)

    def create_link(self, file, dst):
        makepath(os.path.dirname(dst))

        tree = self.pygit2tree
        oid = tree[file].id
        blob = self.pygit2repository[oid]

        delete_old_file(dst)
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
            res.append(os.path.dirname(self.relpath))

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
            if (fullpath.startswith(os.path.join(xxxpwd, "out") + "/") or
                fullpath == os.path.join(xxxpwd, "out")):
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
    def master(self):
        return xxxpwd

    def find_changed(self, dirstate):
        return []

    def find_siblings_and_types(self, dirstate, dummy):
        res = []
        for repo in dirstate.mdata.repos:
            print repo
            res.append([repo, "dir"])
        return res

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
        while True:
            try:
                r = self.repos[path]
                return (r, path)
            except KeyError:
                pass

            path = os.path.dirname(path)

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

        if path is None:
            return

        if not dirstate.changed(os.path.dirname(path)):
            return

        if itemtype == "dir":
            if dirstate.changed(path):
                makepath(os.path.join(outdir, path))
            else:
                makepath(os.path.join(outdir, os.path.dirname(path)))
                if not os.path.lexists(os.path.join(outdir, path)):
                    if r is not None:
                        target = os.path.join(r.master(), gitpath)
                    else:
                        target = os.path.join(xxxpwd, path)
                    symlink_relative(target, os.path.dirname(os.path.join(outdir, path)),
                                     os.path.basename(path))
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
            makepath(outdir)

        lock = threading.Lock()
        q1 = Queue.Queue()
        q2 = Queue.Queue()

        def thr_changed(changed):
            while True:
                repo = q1.get()
                lchanged = self.mdata.repos[repo].find_changed(self)
                with lock:
                    changed += lchanged
                q1.task_done()

        def thr_siblings_and_types(types):
            while True:
                repo = q2.get()
                ltypes = self.mdata.repos[repo].find_siblings_and_types(self, repo)
                with lock:
                    types += ltypes
                q2.task_done()

        threads = []
        changed = []
        for count in range(128):
            threads.append(threading.Thread(target=thr_changed, args=[changed]))
        for t in threads:
            t.daemon = True
            t.start()
        for repo in self.mdata.repos:
            q1.put(repo)

        q1.join()

        for path in changed:
            self.store_item(path, Item(path, changed=1))

        threads = []
        types = []
        for count in range(128):
            threads.append(threading.Thread(target=thr_siblings_and_types, args=[types]))
        for t in threads:
            t.daemon = True
            t.start()
        for repo in self.mdata.repos:
            q2.put(repo)

        q2.join()

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
            if item.repo != "":
                item.gitpath = os.path.relpath(path, item.repo)
            else:
                item.gitpath = path

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

        if (directory in self.items and
            (self.changed(directory) or not item.changed)):
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

    other_repos = []
    for path, dirs, files in os.walk(os.path.join(xxxoutdir, "other-repositories")):
        if ".git" in dirs:
            other_repos.append(path)

    for repo in other_repos:
        name=stripprefix(repo, os.path.join(xxxoutdir, "other-repositories")+"/")
        linkdir=os.path.join(xxxoutdir, "repos-by-name", name)
        print "repo", name, linkdir

        makepath(linkdir)
        symlink_absolute(os.path.join(xxxoutdir, "other-repositories", name),
                         linkdir, "repo")

def write_versions(mdata):
    for repo in mdata.repos:
        r = mdata.repos[repo]
        if isinstance(r, RoEmptyRepository):
            continue
        head = ""
        name = r.name
        url = r.url
        try:
            head = r.head()
        except:
            pass
        try:
            comment = r.git("log", "-1", head)
        except:
            comment = ""
        comment = "# "+"\n# ".join(comment.split("\n"))
        makepath(os.path.join(xxxoutdir, "head-py", ".pipcet-ro", "versions", repo))

        f = open(os.path.join(xxxoutdir, "head-py", ".pipcet-ro", "versions", repo, "version.txt"), 'wb')
        f.write(repo + "/: " + head + " " + name + " " + url + "\n" + comment + "\n")
        f.close()

def backtick(cwd, *args):
    proc = subprocess.Popen([arg for arg in args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            cwd=cwd)
    (out, err) = proc.communicate()
    return out.rstrip()

xxxoutdir = "/home/pip/tmp-repo-overlay"

date = "March.1"

setup_repo_links()

if args.new_versions:
    os.system("echo rm -rf " + xxxoutdir + "/head/.pipcet-ro/versions/*")
    os.system("rm -rf " + xxxoutdir + "/head-py")

if args.new_versions:
    manifest_head = backtick(xxxpwd + "/.repo/manifests", "git", "log", "-1", "--first-parent", "--pretty=tformat:%H", "--until='" + date + "'")
    print "manifest_head", manifest_head
else:
    manifest_head = ManifestData().read_version(".repo/manifests")

mdata_head = ManifestData(version=manifest_head, date=date)
dirstate_head = DirState(mdata_head)

dirstate_head.snapshot("/home/pip/tmp-repo-overlay/head-py")

write_versions(mdata_head)
