export default {

	verifyHash: async (password, hash) => {
		return dcodeIO.bcrypt.compareSync(password, hash)
	},

	signIn: async () => {
		const password = password_value.text;

		const [user] = await findUserByEmail.run();

		if (user && this.verifyHash(password, user?.password_hash)) {
			storeValue('token', await this.createToken(user), true)
				.then(() => updateLoginHistory.run({
				id: user.id
			}))
				.then(() => showAlert('Login success', 'success'))
		} else {
			return showAlert('Invalid email/password', 'error');
		}
	},

	createToken: async (user) => {
		return jsonwebtoken.sign(user, 'secret', {expiresIn: 60*60});
	},

	test: async () => {
		const password = "696k2iyi";
		const hash = dcodeIO.bcrypt.hashSync(password, 10);

		console.log(hash);
	}
}