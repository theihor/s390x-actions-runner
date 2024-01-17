#!/bin/bash

update_fresh_container() {
    echo "Upgrading and installing packages"
    sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install alien -y
    if [ $? -ne 0 ]; then
        exit 32
    fi
    sudo apt autoclean
}

setup_dotnet_sdk() {
    MIRROR="https://mirror.lchs.network/pub/almalinux/9.3/AppStream/${ARCH}/os/Packages"
    case "${ARCH}" in 
        ppc64le)
            PKGS="dotnet-apphost-pack-7.0-7.0.15-1.el9_3 dotnet-host-8.0.1-1.el9_3"
            PKGS="${PKGS} dotnet-hostfxr-7.0-7.0.15-1.el9_3 dotnet-targeting-pack-7.0-7.0.15-1.el9_3"
            PKGS="${PKGS} dotnet-templates-7.0-7.0.115-1.el9_3 dotnet-runtime-7.0-7.0.15-1.el9_3"
            PKGS="${PKGS} dotnet-sdk-7.0-7.0.115-1.el9_3"
            ;;
        s390x)
            PKGS="dotnet-host-8.0.1-1.el9_3 dotnet-apphost-pack-6.0-6.0.26-1.el9_3"
            PKGS="${PKGS} dotnet-hostfxr-6.0-6.0.26-1.el9_3 dotnet-targeting-pack-6.0-6.0.26-1.el9_3"
            PKGS="${PKGS} dotnet-templates-6.0-6.0.126-1.el9_3 dotnet-runtime-6.0-6.0.26-1.el9_3"
            PKGS="${PKGS} dotnet-sdk-6.0-6.0.126-1.el9_3"
            ;;
        *)
            echo "Unsupported architecture ${ARCH}" >&2
            return 1
            ;;
    esac
    echo "Retrieving dotnet packages"
    pushd /tmp >/dev/null
    for pkg in ${PKGS}
    do
        RPM="${pkg}.${ARCH}.rpm"
        wget -q ${MIRROR}/${RPM}
        echo -n "Converting ${RPM}... "
        sudo alien -d ${RPM} |& grep -v ^warning
        if [ $? -ne 0 ]; then
            return 2
        fi
        rm -f ${RPM}
    done

    echo "Installing dotnet"
    sudo DEBIAN_FRONTEND=noninteractive dpkg --install /tmp/dotnet-*.deb
    if [ $? -ne 0 ]; then
        return 3
    fi
    sudo rm -f /tmp/dotnet-*.deb
    popd >/dev/null

    echo "Using SDK - `dotnet --version`"

    # fix ownership
    sudo chown ubuntu:ubuntu /home/ubuntu/.bashrc

    sudo chmod +x /etc/rc.local
    sudo systemctl start rc-local

    return 0
}

patch_runner() {
    echo "Patching runner"
    cd /tmp
    git clone -q ${RUNNERREPO}
    cd runner
    git checkout $(git describe --tags $(git rev-list --tags --max-count=1)) -b ${ARCH}
    git apply /home/ubuntu/runner-${ARCH}.patch
    return $?
}

build_runner() {
    echo "Building runner binary"
    cd src

    echo "dev layout"
    ./dev.sh layout

    if [ $? -eq 0 ]; then
        echo "dev package"
        ./dev.sh package 

        if [ $? -eq 0 ]; then
            echo "Finished building runner binary"

            echo "Running tests"
            ./dev.sh test
        fi
    fi

    return $?
}

install_runner() {
    echo "Installing runner"
    sudo mkdir -p /opt/runner 
    sudo tar -xf /tmp/runner/_package/*.tar.gz -C /opt/runner
    if [ $? -eq 0 ]; then
        sudo chown ubuntu:ubuntu -R /opt/runner
        /opt/runner/config.sh --version
        #TODO: Verify that the version is the _actual_ latest runner
    fi
    return $?
}

cleanup() {
    rm -rf /home/ubuntu/build-image.sh /home/ubuntu/runner-${ARCH}.patch /tmp/runner
}

run() {
    update_fresh_container
    setup_dotnet_sdk
    RC=$?
    if [ ${RC} -eq 0 ]; then
        patch_runner
        RC=$?
        if [ ${RC} -eq 0 ]; then
            build_runner
            RC=$?
            if [ ${RC} -eq 0 ]; then
                install_runner
                RC=$?
            fi
        fi
    fi
    cleanup
    return ${RC}
}

export HOME=/home/ubuntu
ARCH=`uname -m`
RUNNERREPO="https://github.com/actions/runner"
while getopts "a:" opt
do
    case ${opt} in
        a)
            RUNNERREPO=${OPTARG}
            ;;
        *)
            exit 4
            ;;
    esac
done
shift $(( OPTIND - 1 ))
run "$@"
exit $?
