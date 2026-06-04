# To-Do — k3s-gitops Repository Generator

This document contains next steps or items I need to work on to help support the running of this whole shindig.

## Items
1. Figure out a way to either automatically add `ubuntu ALL=(ALL) NOPASSWD:ALL` to `/etc/sudoers.d/ubuntu`
  a. Maybe a one-off Ansible task to copy over a pre-written file? Liable to run into the same permissions issue. 