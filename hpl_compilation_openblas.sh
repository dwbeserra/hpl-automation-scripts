#!/bin/bash
set -euo pipefail

# Optimized compiler flags
OPT_FLAGS="-O3 -march=native -ffast-math -fopenmp -mtune=native"

# Install dependencies with Fortran support
sudo apt-get update
sudo apt-get install -y \
    gcc \
    gfortran \
    make \
    wget \
    tar \
    sed \
    lsb-release \
    pkg-config \
    openmpi-bin \
    libopenmpi-dev \
    libopenblas-dev

# Detect MPI flags automatically
MPI_INC_FLAGS="$(mpicc --showme:compile 2>/dev/null || true)"
MPI_LINK_FLAGS="$(mpicc --showme:link 2>/dev/null || true)"

# Fallbacks if mpicc does not return flags
[ -n "$MPI_INC_FLAGS" ] || MPI_INC_FLAGS="-I/usr/include/openmpi"
[ -n "$MPI_LINK_FLAGS" ] || MPI_LINK_FLAGS="-L/usr/lib/openmpi -lmpi"

# Detect OpenBLAS flags automatically
if pkg-config --exists openblas 2>/dev/null; then
    OPENBLAS_FLAGS="$(pkg-config --libs openblas)"
else
    OPENBLAS_LIB="$(ldconfig -p | awk '/libopenblas\.so/{print $NF; exit}')"
    if [ -z "${OPENBLAS_LIB:-}" ]; then
        echo "Error: OpenBLAS not found after installation." >&2
        exit 1
    fi
    OPENBLAS_DIR="$(dirname "$OPENBLAS_LIB")"
    OPENBLAS_FLAGS="-L${OPENBLAS_DIR} -lopenblas -lpthread -lm -lgfortran"
fi

# Ensure gfortran runtime is included
case " $OPENBLAS_FLAGS " in
    *" -lgfortran "*) ;;
    *) OPENBLAS_FLAGS="${OPENBLAS_FLAGS} -lgfortran" ;;
esac

# Download and extract HPL
rm -rf hpl-2.3 hpl-2.3.tar.gz
wget http://www.netlib.org/benchmark/hpl/hpl-2.3.tar.gz
tar -xzvf hpl-2.3.tar.gz
cd hpl-2.3

# Generate generic Makefile
cd setup
sh make_generic
cd ..
cp setup/Make.UNKNOWN Make.rpi

# Get absolute path to HPL directory
HPL_DIR="$(pwd)"

# Modify Make.rpi with optimized flags and OpenBLAS
sed -i "s/^ARCH\s*=.*/ARCH         = rpi/" Make.rpi
sed -i "s|^TOPdir\s*=.*|TOPdir       = ${HPL_DIR}|" Make.rpi
sed -i "s|^MPdir\s*=.*|MPdir        = /usr|" Make.rpi
sed -i "s|^MPinc\s*=.*|MPinc        = ${MPI_INC_FLAGS}|" Make.rpi
sed -i "s|^MPlib\s*=.*|MPlib        = ${MPI_LINK_FLAGS}|" Make.rpi
sed -i "s|^LAlib\s*=.*|LAlib        = ${OPENBLAS_FLAGS}|" Make.rpi
sed -i "s/^CCFLAGS\s*=.*/CCFLAGS     = \$(HPL_DEFS) ${OPT_FLAGS}/" Make.rpi
sed -i "s/^LINKER\s*=.*/LINKER      = mpicc ${OPT_FLAGS}/" Make.rpi
sed -i "s/^CC\s*=.*/CC            = mpicc/" Make.rpi

# Clean previous build if possible
make clean >/dev/null 2>&1 || true

# Compile HPL
make arch=rpi

# Save compilation info
compiler_name="$(gcc --version | head -n1 | awk '{print $1}')"
compiler_version="$(gcc --version | head -n1 | awk '{print $NF}')"
mpi_version="$(mpirun --version 2>/dev/null | head -n1 | awk '{print $NF}')"
openblas_version="$(dpkg-query -W -f='${Version}' libopenblas-dev 2>/dev/null || echo "Unknown")"
os_info="$(lsb_release -ds 2>/dev/null || echo "Unknown")"

combined_flags="${OPT_FLAGS} ${MPI_INC_FLAGS} ${MPI_LINK_FLAGS} ${OPENBLAS_FLAGS}"
combined_flags="$(echo "$combined_flags" | tr ' ' ',' | sed 's/,,*/,/g')"

mpi_version="${mpi_version:-Unknown}"
openblas_version="${openblas_version:-Unknown}"

{
  echo "compiler_name:$compiler_name"
  echo "compiler_version:$compiler_version"
  echo "compiler_flags:\"${combined_flags}\""
  echo "mpi_version:$mpi_version"
  echo "openblas_version:$openblas_version"
  echo "hpl_version:2.3"
  echo "os_info:\"$os_info\""
  echo "compilation_date:$(date +%Y-%m-%d)"
} > hpl_compilation_info.csv

echo "HPL installation completed successfully (I hope)!"
