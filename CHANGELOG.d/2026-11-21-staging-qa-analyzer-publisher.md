### Staging QA analyzer image publisher

- Add a staging-only immutable analyzer repository and a dedicated GitHub OIDC publisher.
- A manual run on main publishes the Linux amd64 image under the full commit SHA and verifies its
  registry digest and recorded source revision before reporting the pin for the staging env plan.
