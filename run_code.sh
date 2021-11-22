#!/bin/bash
docker container prune --force
docker image rm defi-mooc-lab2
docker build -t defi-mooc-lab2 .
docker run -e ALCHE_API="tNJyZhotmyPGinaV9UBYJziuMwH04Isf" -it defi-mooc-lab2 npm test
