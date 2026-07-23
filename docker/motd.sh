#!/usr/bin/env bash
# Prints the vcfctl quick-help. Also installed as `vcfctl-help`.
set -uo pipefail

VCF_VERSION=$(vcf version 2>/dev/null | awk '/^version:/{print $2}')
KUBECTL_VERSION=$(kubectl version --client 2>/dev/null | awk '/Client Version:/{print $3}')

cat <<EOF
─────────────────────────────────────────────────────────────────────
 vcfctl — VCF 9 & vSphere 8 VKS toolbox (air-gap ready)
 vcf ${VCF_VERSION:-?} · kubectl ${KUBECTL_VERSION:-?} · all VCF plugins preinstalled

 Log in to a VKS environment:
   supervisor-login -e <supervisor-fqdn> -u <user@domain>   direct Supervisor (VCF 9)
   vcfa-login -e <vcfa-fqdn> -o <org>                       VCF Automation (CCI)
   tkgs-login -e <supervisor-ip> -u <user@domain>           vSphere 8 / TKGS (installs
                                 kubectl-vsphere from your Supervisor on first use)
   Add --help to any command for all options.

 Useful:
   vcf context list / use        manage VCF contexts
   vcf cluster list              list VKS clusters (CCI context)
   kubectl config get-contexts   kubeconfig contexts
   fetch-ca <host>               print a server's CA certificate (PEM)
   vcfctl-help                   show this message again

 Persistence: mount a volume at /home/vcfctl to keep contexts and
 kubeconfigs across runs:
   docker run -it --rm -v vcfctl-home:/home/vcfctl:z <image>
─────────────────────────────────────────────────────────────────────
EOF
