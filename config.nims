# Lets `nim r tests/...` find the package from the repo, and a sibling nanuq
# checkout (../nanuq) if there is one, before the nimble-installed package.
switch("path", thisDir() & "/src")
if dirExists(thisDir() & "/../nanuq/src"):
  switch("path", thisDir() & "/../nanuq/src")
